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
    }

    val engine = EngineBridge()
    private var engineReady = false
    private var kbView: KeyboardView? = null
    private var candView: CandidateView? = null

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

    override fun onCreateInputView(): View {
        val view = KeyboardView(this)
        view.setIME(this)
        kbView = view
        // 首次创建时应用一次配置
        applyConfig()
        return view
    }

    override fun onCreateCandidatesView(): View {
        val view = CandidateView(this)
        view.setIME(this)
        candView = view
        setCandidatesViewShown(false)
        return view
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
        if (engineReady) {
            engine.nativeHandleEscape()
        }
        setCandidatesViewShown(false)
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

        processResult(result)
    }

    fun onPunctuation(ch: Char) {
        if (!engineReady) {
            currentInputConnection?.commitText(ch.toString(), 1)
            return
        }
        processResult(engine.nativeHandlePunctuation(ch.code.toByte()))
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

    private fun processResult(result: EngineBridge.EngineResult) {
        val ic = currentInputConnection ?: return
        when (result.action) {
            EngineBridge.EngineResult.ACTION_COMMIT -> {
                ic.finishComposingText()
                if (!result.text.isNullOrEmpty()) {
                    ic.commitText(result.text, 1)
                }
                updateUI()
            }
            EngineBridge.EngineResult.ACTION_UPDATE -> {
                updateUI()
            }
            EngineBridge.EngineResult.ACTION_RESET -> {
                ic.finishComposingText()
                updateUI()
            }
            EngineBridge.EngineResult.ACTION_UNHANDLED -> {
                // 透传到应用
            }
        }
    }

    private fun updateUI() {
        val ic = currentInputConnection ?: return
        val buffer = engine.nativeGetBuffer()
        val candidates = engine.nativeGetCandidates()

        if (buffer.isEmpty() && candidates.isEmpty()) {
            ic.finishComposingText()
            setCandidatesViewShown(false)
        } else {
            ic.setComposingText(buffer, 1)
            setCandidatesViewShown(candidates.isNotEmpty())
        }

        candView?.update(buffer, candidates)
        kbView?.updateModeIndicator(engine.nativeGetMode())
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
