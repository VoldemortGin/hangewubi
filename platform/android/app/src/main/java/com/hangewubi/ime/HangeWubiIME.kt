package com.hangewubi.ime

import android.content.SharedPreferences
import android.inputmethodservice.InputMethodService
import android.preference.PreferenceManager
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
    private lateinit var kbView: KeyboardView
    private lateinit var candView: CandidateView

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

            val count = if (pinyinFile.exists()) {
                engine.nativeInitWithPinyin(dictFile.absolutePath, pinyinFile.absolutePath)
            } else {
                engine.nativeInit(dictFile.absolutePath)
            }
            if (count >= 0) {
                engineReady = true
                Log.i(TAG, "Engine initialized with $count wubi entries, pinyin=${pinyinFile.exists()}")
                applyConfig(pinyinFile.exists())
            } else {
                Log.e(TAG, "Engine init failed")
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to init engine", e)
        }
    }

    private fun applyConfig(pinyinDictLoaded: Boolean) {
        val prefs: SharedPreferences = PreferenceManager.getDefaultSharedPreferences(this)
        val autoCommitUnique4 = prefs.getBoolean("auto_commit_unique_4", true)
        val autoCommitFirst5 = prefs.getBoolean("auto_commit_first_5", false)
        val enterKeyAction = prefs.getInt("enter_key_action", 0)
        val emptyCodeAction = prefs.getInt("empty_code_action", 0)
        val candidateCount = prefs.getInt("candidate_count", 5)
        // 默认：拼音词典存在即启用混输，可通过偏好关闭
        val pinyinEnabled = pinyinDictLoaded && prefs.getBoolean("pinyin_mixed_enabled", true)
        engine.nativeSetConfig(
            autoCommitUnique4,
            autoCommitFirst5,
            enterKeyAction,
            emptyCodeAction,
            candidateCount,
            pinyinEnabled
        )
        Log.i(TAG, "Applied config: pinyinMixed=$pinyinEnabled")
    }

    override fun onCreateInputView(): View {
        kbView = KeyboardView(this)
        kbView.setIME(this)
        return kbView
    }

    override fun onCreateCandidatesView(): View {
        candView = CandidateView(this)
        candView.setIME(this)
        setCandidatesViewShown(false)
        return candView
    }

    override fun onStartInput(info: EditorInfo?, restarting: Boolean) {
        super.onStartInput(info, restarting)
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
                // Try as punctuation
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

    fun onCandidateSelected(index: Int) {
        if (!engineReady) return
        // Candidates are 1-indexed in the engine (number key selection)
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
                // Pass through to app
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

        if (::candView.isInitialized) {
            candView.update(buffer, candidates)
        }
        if (::kbView.isInitialized) {
            kbView.updateModeIndicator(engine.nativeGetMode())
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
