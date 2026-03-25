#include <jni.h>
#include <string.h>
#include <android/log.h>
#include "hangewubi.h"

#define LOG_TAG "HangeWubiJNI"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

// Cache class and method IDs for EngineResult and Candidate
static jclass g_engineResultClass = NULL;
static jmethodID g_engineResultCtor = NULL;
static jclass g_candidateClass = NULL;
static jmethodID g_candidateCtor = NULL;

// Helper: create a Java EngineResult from an FfiResult
static jobject make_engine_result(JNIEnv *env, FfiResult result) {
    jstring text = NULL;
    if (result.text != NULL) {
        text = (*env)->NewStringUTF(env, result.text);
        ffi_free_string(result.text);
    }
    return (*env)->NewObject(env, g_engineResultClass, g_engineResultCtor,
                             (jint)result.action, text);
}

// Helper: create a Java Candidate from an FfiCandidate
static jobject make_candidate(JNIEnv *env, const FfiCandidate *c) {
    jstring text = (*env)->NewStringUTF(env, c->text);
    jstring code = (*env)->NewStringUTF(env, c->code);
    return (*env)->NewObject(env, g_candidateClass, g_candidateCtor, text, code);
}

// Called when the native library is loaded
JNIEXPORT jint JNI_OnLoad(JavaVM *vm, void *reserved) {
    JNIEnv *env;
    if ((*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6) != JNI_OK) {
        return JNI_ERR;
    }

    // Cache EngineResult class and constructor
    jclass cls = (*env)->FindClass(env, "com/hangewubi/ime/EngineBridge$EngineResult");
    if (cls == NULL) {
        LOGE("Failed to find EngineResult class");
        return JNI_ERR;
    }
    g_engineResultClass = (*env)->NewGlobalRef(env, cls);
    g_engineResultCtor = (*env)->GetMethodID(env, g_engineResultClass, "<init>",
                                              "(ILjava/lang/String;)V");
    if (g_engineResultCtor == NULL) {
        LOGE("Failed to find EngineResult constructor");
        return JNI_ERR;
    }

    // Cache Candidate class and constructor
    cls = (*env)->FindClass(env, "com/hangewubi/ime/EngineBridge$Candidate");
    if (cls == NULL) {
        LOGE("Failed to find Candidate class");
        return JNI_ERR;
    }
    g_candidateClass = (*env)->NewGlobalRef(env, cls);
    g_candidateCtor = (*env)->GetMethodID(env, g_candidateClass, "<init>",
                                          "(Ljava/lang/String;Ljava/lang/String;)V");
    if (g_candidateCtor == NULL) {
        LOGE("Failed to find Candidate constructor");
        return JNI_ERR;
    }

    LOGI("JNI_OnLoad complete");
    return JNI_VERSION_1_6;
}

JNIEXPORT jlong JNICALL
Java_com_hangewubi_ime_EngineBridge_nativeInit(JNIEnv *env, jobject obj, jstring dictPath) {
    const char *path = (*env)->GetStringUTFChars(env, dictPath, NULL);
    if (path == NULL) return -1;

    int64_t count = ffi_init(path);
    LOGI("ffi_init(\"%s\") returned %lld", path, (long long)count);

    (*env)->ReleaseStringUTFChars(env, dictPath, path);
    return (jlong)count;
}

JNIEXPORT jobject JNICALL
Java_com_hangewubi_ime_EngineBridge_nativeHandleKey(JNIEnv *env, jobject obj, jbyte key) {
    FfiResult result = ffi_handle_key((char)key);
    return make_engine_result(env, result);
}

JNIEXPORT jobject JNICALL
Java_com_hangewubi_ime_EngineBridge_nativeHandleSpace(JNIEnv *env, jobject obj) {
    FfiResult result = ffi_handle_space();
    return make_engine_result(env, result);
}

JNIEXPORT jobject JNICALL
Java_com_hangewubi_ime_EngineBridge_nativeHandleBackspace(JNIEnv *env, jobject obj) {
    FfiResult result = ffi_handle_backspace();
    return make_engine_result(env, result);
}

JNIEXPORT jobject JNICALL
Java_com_hangewubi_ime_EngineBridge_nativeHandleEscape(JNIEnv *env, jobject obj) {
    FfiResult result = ffi_handle_escape();
    return make_engine_result(env, result);
}

JNIEXPORT jobject JNICALL
Java_com_hangewubi_ime_EngineBridge_nativeHandleEnter(JNIEnv *env, jobject obj) {
    FfiResult result = ffi_handle_enter();
    return make_engine_result(env, result);
}

JNIEXPORT jobject JNICALL
Java_com_hangewubi_ime_EngineBridge_nativeHandleNumber(JNIEnv *env, jobject obj, jint num) {
    FfiResult result = ffi_handle_number((uint8_t)num);
    return make_engine_result(env, result);
}

JNIEXPORT jobject JNICALL
Java_com_hangewubi_ime_EngineBridge_nativeHandleSemicolon(JNIEnv *env, jobject obj) {
    FfiResult result = ffi_handle_semicolon();
    return make_engine_result(env, result);
}

JNIEXPORT jobject JNICALL
Java_com_hangewubi_ime_EngineBridge_nativeHandleQuote(JNIEnv *env, jobject obj) {
    FfiResult result = ffi_handle_quote();
    return make_engine_result(env, result);
}

JNIEXPORT jobject JNICALL
Java_com_hangewubi_ime_EngineBridge_nativeHandlePunctuation(JNIEnv *env, jobject obj, jbyte ch) {
    FfiResult result = ffi_handle_punctuation((char)ch);
    return make_engine_result(env, result);
}

JNIEXPORT jobject JNICALL
Java_com_hangewubi_ime_EngineBridge_nativeNextPage(JNIEnv *env, jobject obj) {
    FfiResult result = ffi_next_page();
    return make_engine_result(env, result);
}

JNIEXPORT jobject JNICALL
Java_com_hangewubi_ime_EngineBridge_nativePrevPage(JNIEnv *env, jobject obj) {
    FfiResult result = ffi_prev_page();
    return make_engine_result(env, result);
}

JNIEXPORT void JNICALL
Java_com_hangewubi_ime_EngineBridge_nativeToggleMode(JNIEnv *env, jobject obj) {
    ffi_toggle_mode();
}

JNIEXPORT jint JNICALL
Java_com_hangewubi_ime_EngineBridge_nativeGetMode(JNIEnv *env, jobject obj) {
    return (jint)ffi_get_mode();
}

JNIEXPORT jstring JNICALL
Java_com_hangewubi_ime_EngineBridge_nativeGetBuffer(JNIEnv *env, jobject obj) {
    char *buf = ffi_get_buffer();
    jstring result = (*env)->NewStringUTF(env, buf ? buf : "");
    if (buf) ffi_free_string(buf);
    return result;
}

JNIEXPORT jobjectArray JNICALL
Java_com_hangewubi_ime_EngineBridge_nativeGetCandidates(JNIEnv *env, jobject obj) {
    FfiCandidateList list = ffi_get_candidates();

    jobjectArray array = (*env)->NewObjectArray(env, (jsize)list.count,
                                                 g_candidateClass, NULL);
    for (size_t i = 0; i < list.count; i++) {
        jobject c = make_candidate(env, &list.candidates[i]);
        (*env)->SetObjectArrayElement(env, array, (jsize)i, c);
        (*env)->DeleteLocalRef(env, c);
    }

    ffi_free_candidate_list(list);
    return array;
}

JNIEXPORT void JNICALL
Java_com_hangewubi_ime_EngineBridge_nativeSetConfig(JNIEnv *env, jobject obj,
        jboolean autoCommitUnique4, jboolean autoCommitFirst5,
        jint enterKeyAction, jint emptyCodeAction, jint candidateCount) {
    ffi_set_config(autoCommitUnique4, autoCommitFirst5,
                   (uint8_t)enterKeyAction, (uint8_t)emptyCodeAction,
                   (uint8_t)candidateCount);
}

JNIEXPORT void JNICALL
Java_com_hangewubi_ime_EngineBridge_nativeAddUserWord(JNIEnv *env, jobject obj,
        jstring code, jstring text) {
    const char *c = (*env)->GetStringUTFChars(env, code, NULL);
    const char *t = (*env)->GetStringUTFChars(env, text, NULL);
    if (c && t) {
        ffi_add_user_word(c, t);
    }
    if (c) (*env)->ReleaseStringUTFChars(env, code, c);
    if (t) (*env)->ReleaseStringUTFChars(env, text, t);
}

JNIEXPORT jboolean JNICALL
Java_com_hangewubi_ime_EngineBridge_nativeSaveUserDict(JNIEnv *env, jobject obj, jstring path) {
    const char *p = (*env)->GetStringUTFChars(env, path, NULL);
    if (p == NULL) return JNI_FALSE;

    bool ok = ffi_save_user_dict(p);
    (*env)->ReleaseStringUTFChars(env, path, p);
    return ok ? JNI_TRUE : JNI_FALSE;
}
