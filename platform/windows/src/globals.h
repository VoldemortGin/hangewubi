#ifndef HANGEWUBI_TSF_GLOBALS_H
#define HANGEWUBI_TSF_GLOBALS_H

#include <windows.h>
#include <ole2.h>
#include <msctf.h>
#include <ctffunc.h>

// CLSID for HangeWubi Text Service
// {7E8D4F1A-3B2C-4D5E-A6F7-890123456789}
static const CLSID CLSID_HangeWubiTextService = {
    0x7E8D4F1A, 0x3B2C, 0x4D5E,
    { 0xA6, 0xF7, 0x89, 0x01, 0x23, 0x45, 0x67, 0x89 }
};

// GUID for the language profile
// {8F9E5A2B-4C3D-5E6F-B7A8-901234567ABC}
static const GUID GUID_HangeWubiProfile = {
    0x8F9E5A2B, 0x4C3D, 0x5E6F,
    { 0xB7, 0xA8, 0x90, 0x12, 0x34, 0x56, 0x7A, 0xBC }
};

// GUID for display attribute
// {A1B2C3D4-5E6F-7A8B-C9D0-E1F234567890}
static const GUID GUID_HangeWubiDisplayAttribute = {
    0xA1B2C3D4, 0x5E6F, 0x7A8B,
    { 0xC9, 0xD0, 0xE1, 0xF2, 0x34, 0x56, 0x78, 0x90 }
};

// GUID for the candidate list UI element
// {B2C3D4E5-6F7A-8B9C-D0E1-F23456789012}
static const GUID GUID_HangeWubiCandidateUI = {
    0xB2C3D4E5, 0x6F7A, 0x8B9C,
    { 0xD0, 0xE1, 0xF2, 0x34, 0x56, 0x78, 0x90, 0x12 }
};

// Language: Chinese Simplified
#define HANGEWUBI_LANGID    MAKELANGID(LANG_CHINESE, SUBLANG_CHINESE_SIMPLIFIED)

// Display name
#define HANGEWUBI_DISPLAY_NAME      L"\x51FD\x6208\x4E94\x7B14"  // 函戈五笔
#define HANGEWUBI_DISPLAY_NAME_EN   L"HangeWubi"

// Global reference count for DLL unloading
extern LONG g_dllRefCount;
extern HINSTANCE g_hInst;

// Helper to increment/decrement DLL ref count
inline void DllAddRef()  { InterlockedIncrement(&g_dllRefCount); }
inline void DllRelease() { InterlockedDecrement(&g_dllRefCount); }

#endif // HANGEWUBI_TSF_GLOBALS_H
