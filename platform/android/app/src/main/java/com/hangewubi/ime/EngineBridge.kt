package com.hangewubi.ime

class EngineBridge {

    data class EngineResult(val action: Int, val text: String?) {
        companion object {
            const val ACTION_COMMIT = 0
            const val ACTION_UPDATE = 1
            const val ACTION_RESET = 2
            const val ACTION_UNHANDLED = 3
        }
    }

    data class Candidate(val text: String, val code: String)

    companion object {
        init {
            System.loadLibrary("hangewubi_jni")
        }
    }

    external fun nativeInit(dictPath: String): Long
    external fun nativeInitWithPinyin(dictPath: String, pinyinDictPath: String): Long
    external fun nativeHandleKey(key: Byte): EngineResult
    external fun nativeHandleSpace(): EngineResult
    external fun nativeHandleBackspace(): EngineResult
    external fun nativeHandleEscape(): EngineResult
    external fun nativeHandleEnter(): EngineResult
    external fun nativeHandleNumber(num: Int): EngineResult
    external fun nativeHandleSemicolon(): EngineResult
    external fun nativeHandleQuote(): EngineResult
    external fun nativeHandlePunctuation(ch: Byte): EngineResult
    external fun nativeNextPage(): EngineResult
    external fun nativePrevPage(): EngineResult
    external fun nativeToggleMode()
    external fun nativeGetMode(): Int
    external fun nativeGetBuffer(): String
    external fun nativeGetCandidates(): Array<Candidate>
    external fun nativeSetConfig(
        autoCommitUnique4: Boolean,
        autoCommitFirst5: Boolean,
        enterKeyAction: Int,
        emptyCodeAction: Int,
        candidateCount: Int,
        pinyinMixedEnabled: Boolean
    )
    external fun nativeAddUserWord(code: String, text: String)
    external fun nativeSaveUserDict(path: String): Boolean
}
