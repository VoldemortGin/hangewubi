#include "globals.h"
#include "class_factory.h"
#include <new>

// Global variables
LONG g_dllRefCount = 0;
HINSTANCE g_hInst = nullptr;

// DLL entry point
BOOL WINAPI DllMain(HINSTANCE hInstance, DWORD dwReason, LPVOID /*lpReserved*/)
{
    switch (dwReason) {
    case DLL_PROCESS_ATTACH:
        g_hInst = hInstance;
        DisableThreadLibraryCalls(hInstance);
        break;
    case DLL_PROCESS_DETACH:
        break;
    }
    return TRUE;
}

// ─────────────────────── COM Registration Helpers ───────────────────────

static HRESULT RegisterCOMServer()
{
    // Register CLSID under HKCR\CLSID\{...}
    wchar_t clsidStr[64];
    StringFromGUID2(CLSID_HangeWubiTextService, clsidStr, 64);

    wchar_t keyPath[256];
    swprintf(keyPath, 256, L"CLSID\\%s", clsidStr);

    HKEY hKey = nullptr;
    LONG result = RegCreateKeyExW(HKEY_CLASSES_ROOT, keyPath, 0, nullptr,
                                   REG_OPTION_NON_VOLATILE, KEY_WRITE, nullptr, &hKey, nullptr);
    if (result != ERROR_SUCCESS) return E_FAIL;

    // Set default value to display name
    RegSetValueExW(hKey, nullptr, 0, REG_SZ,
                   (const BYTE *)HANGEWUBI_DISPLAY_NAME,
                   (DWORD)((wcslen(HANGEWUBI_DISPLAY_NAME) + 1) * sizeof(wchar_t)));
    RegCloseKey(hKey);

    // Register InprocServer32
    wchar_t inprocPath[256];
    swprintf(inprocPath, 256, L"CLSID\\%s\\InprocServer32", clsidStr);

    result = RegCreateKeyExW(HKEY_CLASSES_ROOT, inprocPath, 0, nullptr,
                              REG_OPTION_NON_VOLATILE, KEY_WRITE, nullptr, &hKey, nullptr);
    if (result != ERROR_SUCCESS) return E_FAIL;

    // Set DLL path
    wchar_t dllPath[MAX_PATH];
    GetModuleFileNameW(g_hInst, dllPath, MAX_PATH);
    RegSetValueExW(hKey, nullptr, 0, REG_SZ,
                   (const BYTE *)dllPath,
                   (DWORD)((wcslen(dllPath) + 1) * sizeof(wchar_t)));

    // Threading model
    const wchar_t *threadModel = L"Apartment";
    RegSetValueExW(hKey, L"ThreadingModel", 0, REG_SZ,
                   (const BYTE *)threadModel,
                   (DWORD)((wcslen(threadModel) + 1) * sizeof(wchar_t)));
    RegCloseKey(hKey);

    return S_OK;
}

static HRESULT UnregisterCOMServer()
{
    wchar_t clsidStr[64];
    StringFromGUID2(CLSID_HangeWubiTextService, clsidStr, 64);

    wchar_t keyPath[256];
    swprintf(keyPath, 256, L"CLSID\\%s\\InprocServer32", clsidStr);
    RegDeleteKeyW(HKEY_CLASSES_ROOT, keyPath);

    swprintf(keyPath, 256, L"CLSID\\%s", clsidStr);
    RegDeleteKeyW(HKEY_CLASSES_ROOT, keyPath);

    return S_OK;
}

static HRESULT RegisterTSFProfile()
{
    // Register as a text input processor
    ITfInputProcessorProfiles *pProfiles = nullptr;
    HRESULT hr = CoCreateInstance(CLSID_TF_InputProcessorProfiles, nullptr,
                                   CLSCTX_INPROC_SERVER,
                                   IID_ITfInputProcessorProfiles,
                                   (void **)&pProfiles);
    if (FAILED(hr)) return hr;

    hr = pProfiles->Register(CLSID_HangeWubiTextService);
    if (SUCCEEDED(hr)) {
        // Get icon path (same as DLL path)
        wchar_t dllPath[MAX_PATH];
        GetModuleFileNameW(g_hInst, dllPath, MAX_PATH);

        hr = pProfiles->AddLanguageProfile(
            CLSID_HangeWubiTextService,
            HANGEWUBI_LANGID,
            GUID_HangeWubiProfile,
            HANGEWUBI_DISPLAY_NAME,
            (ULONG)wcslen(HANGEWUBI_DISPLAY_NAME),
            dllPath, 0,  // icon file path, icon index
            0);          // ordinal
    }
    pProfiles->Release();
    if (FAILED(hr)) return hr;

    // Register the category for TIP (Text Input Processor) keyboard
    ITfCategoryMgr *pCatMgr = nullptr;
    hr = CoCreateInstance(CLSID_TF_CategoryMgr, nullptr,
                           CLSCTX_INPROC_SERVER,
                           IID_ITfCategoryMgr,
                           (void **)&pCatMgr);
    if (SUCCEEDED(hr)) {
        pCatMgr->RegisterCategory(CLSID_HangeWubiTextService,
                                    GUID_TFCAT_TIP_KEYBOARD,
                                    CLSID_HangeWubiTextService);
        pCatMgr->Release();
    }

    return S_OK;
}

static HRESULT UnregisterTSFProfile()
{
    // Unregister profile
    ITfInputProcessorProfiles *pProfiles = nullptr;
    HRESULT hr = CoCreateInstance(CLSID_TF_InputProcessorProfiles, nullptr,
                                   CLSCTX_INPROC_SERVER,
                                   IID_ITfInputProcessorProfiles,
                                   (void **)&pProfiles);
    if (SUCCEEDED(hr)) {
        pProfiles->RemoveLanguageProfile(CLSID_HangeWubiTextService,
                                          HANGEWUBI_LANGID,
                                          GUID_HangeWubiProfile);
        pProfiles->Unregister(CLSID_HangeWubiTextService);
        pProfiles->Release();
    }

    // Unregister category
    ITfCategoryMgr *pCatMgr = nullptr;
    hr = CoCreateInstance(CLSID_TF_CategoryMgr, nullptr,
                           CLSCTX_INPROC_SERVER,
                           IID_ITfCategoryMgr,
                           (void **)&pCatMgr);
    if (SUCCEEDED(hr)) {
        pCatMgr->UnregisterCategory(CLSID_HangeWubiTextService,
                                      GUID_TFCAT_TIP_KEYBOARD,
                                      CLSID_HangeWubiTextService);
        pCatMgr->Release();
    }

    return S_OK;
}

// ─────────────────────── DLL Exports ───────────────────────

STDAPI DllRegisterServer()
{
    HRESULT hr = RegisterCOMServer();
    if (FAILED(hr)) return hr;

    hr = RegisterTSFProfile();
    if (FAILED(hr)) {
        UnregisterCOMServer();
        return hr;
    }

    return S_OK;
}

STDAPI DllUnregisterServer()
{
    UnregisterTSFProfile();
    UnregisterCOMServer();
    return S_OK;
}

STDAPI DllGetClassObject(REFCLSID rclsid, REFIID riid, void **ppvObj)
{
    if (ppvObj == nullptr) return E_INVALIDARG;
    *ppvObj = nullptr;

    if (!IsEqualCLSID(rclsid, CLSID_HangeWubiTextService)) {
        return CLASS_E_CLASSNOTAVAILABLE;
    }

    ClassFactory *pFactory = new (std::nothrow) ClassFactory();
    if (pFactory == nullptr) return E_OUTOFMEMORY;

    HRESULT hr = pFactory->QueryInterface(riid, ppvObj);
    pFactory->Release();
    return hr;
}

STDAPI DllCanUnloadNow()
{
    return (g_dllRefCount <= 0) ? S_OK : S_FALSE;
}
