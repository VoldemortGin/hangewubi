package com.hangewubi.ime

import android.content.Context
import android.content.SharedPreferences
import android.inputmethodservice.InputMethodService
import android.util.Log
import android.view.KeyEvent
import android.view.View
import android.view.inputmethod.EditorInfo
import java.io.File
import java.io.FileOutputStream

class HangeWubiIME : InputMethodService() {

    companion object {
        private const val TAG = "HangeWubiIME"
        private const val USER_DICT_FILENAME = "user_dict.json"
        private const val SAVE_THROTTLE_MS = 10_000L

        // 引擎/用户词典是进程内全局单例，落盘状态用类级共享以串行化多实例
        private val saveExecutor = java.util.concurrent.Executors.newSingleThreadExecutor()
        @Volatile private var userDictDirty = false
        @Volatile private var lastSaveTime = 0L
        private var userDictLoaded = false
    }

    val engine = EngineBridge()
    private var engineReady = false
    private var kbView: KeyboardView? = null
    private var candView: CandidateView? = null
    private var lastMode = -1

    private val prefs: SharedPreferences
        get() = getSharedPreferences(SettingsKey.PREFS_NAME, Context.MODE_PRIVATE)

    private var pinyinDictLoaded = false

    override fun onCreate() {
        super.onCreate()
        initEngine()
    }

    private fun initEngine() {
        try {
            val dataDir = File(filesDir, "data")
            if (!dataDir.exists()) dataDir.mkdirs()

            val dictFile = File(dataDir, "wubi86.txt")
            if (!dictFile.exists()) {
                assets.open("data/wubi86.txt").use { input ->
                    FileOutputStream(dictFile).use { output ->
                        input.copyTo(output)
                    }
                }
                Log.i(TAG, "Copied wubi86.txt to ${dictFile.absolutePath}")
            }

            // 复制拼音词典
            val pinyinFile = File(dataDir, "pinyin.txt")
            if (!pinyinFile.exists()) {
                try {
                    assets.open("data/pinyin.txt").use { input ->
                        FileOutputStream(pinyinFile).use { output ->
                            input.copyTo(output)
                        }
                    }
                    Log.i(TAG, "Copied pinyin.txt to ${pinyinFile.absolutePath}")
                } catch (e: Exception) {
                    Log.w(TAG, "pinyin.txt not found in assets, skipping")
                }
            }

            pinyinDictLoaded = pinyinFile.exists()
            val count = if (pinyinDictLoaded) {
                engine.nativeInitWithPinyin(dictFile.absolutePath, pinyinFile.absolutePath)
            } else {
                engine.nativeInit(dictFile.absolutePath)
            }
            if (count >= 0) {
                engineReady = true
                Log.i(TAG, "Engine initialized with $count wubi entries, pinyin=$pinyinDictLoaded")
                applyConfig()
                loadUserDictOnce()
            } else {
                Log.e(TAG, "Engine init failed")
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to init engine", e)
        }
    }

    private fun applyConfig() {
        if (!engineReady) return
        val p = prefs
        val autoCommitUnique4 = p.getBoolean(SettingsKey.AUTO_COMMIT_UNIQUE_4, true)
        val autoCommitFirst5 = p.getBoolean(SettingsKey.AUTO_COMMIT_FIRST_5, false)
        val enterKeyAction = p.getIntFromString(
            SettingsKey.ENTER_KEY_ACTION,
            SettingsKey.DEFAULT_ENTER_KEY_ACTION
        )
        val emptyCodeAction = p.getIntFromString(
            SettingsKey.EMPTY_CODE_ACTION,
            SettingsKey.DEFAULT_EMPTY_CODE_ACTION
        )
        val candidateCount = p.getIntFromString(
            SettingsKey.CANDIDATE_COUNT,
            SettingsKey.DEFAULT_CANDIDATE_COUNT
        )
        val pinyinEnabled = pinyinDictLoaded && p.getBoolean(SettingsKey.PINYIN_MIXED_ENABLED, true)
        val hapticEnabled = p.getBoolean(SettingsKey.HAPTIC_ENABLED, true)

        engine.nativeSetConfig(
            autoCommitUnique4,
            autoCommitFirst5,
            enterKeyAction,
            emptyCodeAction,
            candidateCount,
            pinyinEnabled
        )
        kbView?.hapticEnabled = hapticEnabled
        Log.i(TAG, "Applied config: pinyinMixed=$pinyinEnabled haptic=$hapticEnabled cand=$candidateCount")
    }

    private val userDictFile: File
        get() = File(filesDir, USER_DICT_FILENAME)

    // 用户词典只在进程内加载一次，避免后续实例用磁盘旧内容覆盖内存中尚未落盘的自学习数据
    private fun loadUserDictOnce() {
        if (userDictLoaded) return
        userDictLoaded = true
        val path = userDictFile.absolutePath
        val loaded = engine.nativeLoadUserDict(path)
        Log.i(TAG, "Loaded user dict: $path -> $loaded")
    }

    private fun markUserDictDirty() {
        userDictDirty = true
    }

    // 按需落盘用户词典：仅在有实际改动时保存，主线程节流，写盘放后台串行队列。
    // force=true 跳过节流（失焦/销毁兜底）。ffi_save_user_dict 内部有全局锁，后台调用安全。
    private fun saveUserDictIfNeeded(force: Boolean) {
        if (!engineReady || !userDictDirty) return
        val now = System.currentTimeMillis()
        if (!force && now - lastSaveTime < SAVE_THROTTLE_MS) return
        userDictDirty = false
        lastSaveTime = now
        val path = userDictFile.absolutePath
        saveExecutor.execute {
            val ok = engine.nativeSaveUserDict(path)
            Log.i(TAG, "Saved user dict: $path -> $ok")
        }
    }

    override fun onCreateInputView(): View {
        // 把候选栏和键盘组合到同一个容器里，不依赖系统的 setCandidatesViewShown
        val container = android.widget.LinearLayout(this).apply {
            orientation = android.widget.LinearLayout.VERTICAL
        }

        val cand = CandidateView(this)
        cand.setIME(this)
        cand.visibility = android.view.View.GONE
        candView = cand
        container.addView(cand)

        val kb = KeyboardView(this)
        kb.setIME(this)
        kbView = kb
        container.addView(kb)

        // 键盘视图重建，强制下次 updateUI 刷新模式指示
        lastMode = -1
        applyConfig()
        return container
    }

    override fun onStartInput(info: EditorInfo?, restarting: Boolean) {
        super.onStartInput(info, restarting)
        // 每次进入输入框都重新读取配置，设置页修改能立即生效
        applyConfig()
        if (!restarting && engineReady) {
            engine.nativeHandleEscape()
            updateUI()
        }
    }

    override fun onFinishInput() {
        super.onFinishInput()
        // 失焦收尾：有候选提交首选、无候选清空预编辑，绝不让原码定稿进文档
        finishComposition()
        if (engineReady) {
            engine.nativeHandleEscape()
        }
        showCandidates(false)
        saveUserDictIfNeeded(force = true)
    }

    override fun onDestroy() {
        saveUserDictIfNeeded(force = true)
        super.onDestroy()
    }

    // 组合被强制结束时的统一收尾：有候选则把当前页首选上屏，无候选则丢弃在途编码。
    // currentInputConnection 可能为 null（如已失焦），判空兜底。
    private fun finishComposition() {
        val ic = currentInputConnection ?: return
        if (engineReady) {
            val candidates = engine.nativeGetCandidates()
            if (candidates.isNotEmpty()) {
                ic.commitText(candidates[0].text, 1)
                return
            }
        }
        ic.setComposingText("", 1)
        ic.finishComposingText()
    }

    fun onKeyPress(keyCode: Int) {
        if (!engineReady) {
            if (keyCode in KeyEvent.KEYCODE_A..KeyEvent.KEYCODE_Z) {
                val ch = ('a' + (keyCode - KeyEvent.KEYCODE_A))
                currentInputConnection?.commitText(ch.toString(), 1)
            }
            return
        }

        val result = when (keyCode) {
            KeyEvent.KEYCODE_SPACE -> engine.nativeHandleSpace()
            KeyEvent.KEYCODE_DEL -> engine.nativeHandleBackspace()
            KeyEvent.KEYCODE_ENTER -> engine.nativeHandleEnter()
            KeyEvent.KEYCODE_ESCAPE -> engine.nativeHandleEscape()
            KeyEvent.KEYCODE_SEMICOLON -> engine.nativeHandleSemicolon()
            KeyEvent.KEYCODE_APOSTROPHE -> engine.nativeHandleQuote()
            in KeyEvent.KEYCODE_0..KeyEvent.KEYCODE_9 -> {
                val num = keyCode - KeyEvent.KEYCODE_0
                engine.nativeHandleNumber(num)
            }
            in KeyEvent.KEYCODE_A..KeyEvent.KEYCODE_Z -> {
                val ch = ('a' + (keyCode - KeyEvent.KEYCODE_A)).code.toByte()
                engine.nativeHandleKey(ch)
            }
            else -> {
                val ch = keyCodeToChar(keyCode)
                if (ch != null) {
                    engine.nativeHandlePunctuation(ch.code.toByte())
                } else {
                    null
                }
            }
        } ?: return

        processResult(result) { handleUnhandledKey(keyCode) }
    }

    fun onPunctuation(ch: Char) {
        if (!engineReady) {
            currentInputConnection?.commitText(ch.toString(), 1)
            return
        }
        processResult(engine.nativeHandlePunctuation(ch.code.toByte())) {
            currentInputConnection?.commitText(ch.toString(), 1)
        }
    }

    fun onCandidateSelected(index: Int) {
        if (!engineReady) return
        // 引擎中数字键选词是 1-indexed
        val result = engine.nativeHandleNumber(index + 1)
        processResult(result)
    }

    fun onToggleMode() {
        if (!engineReady) return
        engine.nativeToggleMode()
        updateUI()
    }

    fun onNextPage() {
        if (!engineReady) return
        val result = engine.nativeNextPage()
        processResult(result)
    }

    fun onPrevPage() {
        if (!engineReady) return
        val result = engine.nativePrevPage()
        processResult(result)
    }

    fun getMode(): Int = if (engineReady) engine.nativeGetMode() else 1

    private fun processResult(
        result: EngineBridge.EngineResult,
        onUnhandled: (() -> Unit)? = null
    ) {
        val ic = currentInputConnection ?: return
        when (result.action) {
            EngineBridge.EngineResult.ACTION_COMMIT -> {
                // commitText 语义会自动替换当前 composing region，无需先 finishComposingText
                if (!result.text.isNullOrEmpty()) {
                    ic.commitText(result.text, 1)
                }
                // 发生了实际提交/选字，引擎可能已更新自造词/词频，标记待落盘
                markUserDictDirty()
                updateUI()
                saveUserDictIfNeeded(force = false)
            }
            EngineBridge.EngineResult.ACTION_UPDATE -> {
                updateUI()
            }
            EngineBridge.EngineResult.ACTION_RESET -> {
                // 清空在途编码（丢弃，不是定稿）
                ic.setComposingText("", 1)
                updateUI()
            }
            EngineBridge.EngineResult.ACTION_UNHANDLED -> {
                // 引擎未消费该键，宿主执行默认动作（退格/回车/字符等）
                onUnhandled?.invoke()
            }
        }
    }

    // 软键盘的所有按键都经此路径，引擎未处理时按键类型做兜底
    private fun handleUnhandledKey(keyCode: Int) {
        val ic = currentInputConnection ?: return
        when (keyCode) {
            KeyEvent.KEYCODE_DEL -> sendDownUpKeyEvents(KeyEvent.KEYCODE_DEL)
            KeyEvent.KEYCODE_ENTER -> handleUnhandledEnter(ic)
            KeyEvent.KEYCODE_SPACE -> ic.commitText(" ", 1)
            in KeyEvent.KEYCODE_0..KeyEvent.KEYCODE_9 -> {
                ic.commitText(('0' + (keyCode - KeyEvent.KEYCODE_0)).toString(), 1)
            }
            in KeyEvent.KEYCODE_A..KeyEvent.KEYCODE_Z -> {
                ic.commitText(('a' + (keyCode - KeyEvent.KEYCODE_A)).toString(), 1)
            }
            else -> keyCodeToChar(keyCode)?.let { ic.commitText(it.toString(), 1) }
        }
    }

    private fun handleUnhandledEnter(ic: android.view.inputmethod.InputConnection) {
        val editorInfo = currentInputEditorInfo
        val imeOptions = editorInfo?.imeOptions ?: 0
        val action = imeOptions and EditorInfo.IME_MASK_ACTION
        val noAction = (imeOptions and EditorInfo.IME_FLAG_NO_ENTER_ACTION) != 0
        if (action != EditorInfo.IME_ACTION_NONE && !noAction) {
            ic.performEditorAction(action)
        } else {
            // 默认换行：发送真实按键事件，兼容多行输入框
            sendDownUpKeyEvents(KeyEvent.KEYCODE_ENTER)
        }
    }

    private fun showCandidates(show: Boolean) {
        candView?.visibility = if (show) android.view.View.VISIBLE else android.view.View.GONE
    }

    private fun updateUI() {
        val ic = currentInputConnection ?: return
        val buffer = engine.nativeGetBuffer()
        val candidates = engine.nativeGetCandidates()

        if (buffer.isEmpty() && candidates.isEmpty()) {
            // 先清空在途预编辑内容再结束组合，避免残留原码被定稿进文档
            ic.setComposingText("", 1)
            ic.finishComposingText()
            showCandidates(false)
        } else {
            ic.setComposingText(buffer, 1)
            showCandidates(candidates.isNotEmpty())
        }

        candView?.update(buffer, candidates)

        // 模式只在切换/临时英文回落时才变，缓存上次值避免每键 invalidate 整个键盘
        val mode = engine.nativeGetMode()
        if (mode != lastMode) {
            lastMode = mode
            kbView?.updateModeIndicator(mode)
        }
    }

    private fun keyCodeToChar(keyCode: Int): Char? {
        return when (keyCode) {
            KeyEvent.KEYCODE_COMMA -> ','
            KeyEvent.KEYCODE_PERIOD -> '.'
            KeyEvent.KEYCODE_SLASH -> '/'
            KeyEvent.KEYCODE_BACKSLASH -> '\\'
            KeyEvent.KEYCODE_MINUS -> '-'
            KeyEvent.KEYCODE_EQUALS -> '='
            KeyEvent.KEYCODE_LEFT_BRACKET -> '['
            KeyEvent.KEYCODE_RIGHT_BRACKET -> ']'
            KeyEvent.KEYCODE_GRAVE -> '`'
            else -> null
        }
    }
}

// Preference 的 ListPreference 存的是字符串，这里容错地按 int 读取。
private fun SharedPreferences.getIntFromString(key: String, default: Int): Int {
    return when (val v = all[key]) {
        is Int -> v
        is String -> v.toIntOrNull() ?: default
        else -> default
    }
}
