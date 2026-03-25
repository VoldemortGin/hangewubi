# hangewubi Android IME ProGuard rules

# Keep JNI bridge class and its inner classes (called from native code)
-keep class com.hangewubi.ime.EngineBridge { *; }
-keep class com.hangewubi.ime.EngineBridge$* { *; }

# Keep InputMethodService
-keep class com.hangewubi.ime.HangeWubiIME { *; }
