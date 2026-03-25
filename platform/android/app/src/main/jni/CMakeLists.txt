cmake_minimum_required(VERSION 3.22.1)
project("hangewubi_jni" C)

# Path to the hangewubi C header
set(HANGEWUBI_INCLUDE_DIR "${CMAKE_SOURCE_DIR}/../../../../include"
    CACHE PATH "Path to hangewubi.h")

# The pre-built Rust shared library (libhangewubi.so) is placed in jniLibs/<abi>/
# by the build.sh script. We declare it as an IMPORTED library so we can link against it.
add_library(hangewubi SHARED IMPORTED)
set_target_properties(hangewubi PROPERTIES
    IMPORTED_LOCATION "${CMAKE_SOURCE_DIR}/../jniLibs/${ANDROID_ABI}/libhangewubi.so"
)

# Build the JNI bridge
add_library(hangewubi_jni SHARED hangewubi_jni.c)

target_include_directories(hangewubi_jni PRIVATE
    ${HANGEWUBI_INCLUDE_DIR}
)

target_link_libraries(hangewubi_jni
    hangewubi
    log
)
