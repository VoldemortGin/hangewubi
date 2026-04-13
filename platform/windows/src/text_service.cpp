#include "text_service.h"
#include <new>
#include <cstring>
#include <cstdio>

// ─────────────────────── TextService ───────────────────────

TextService::TextService()
    : _refCount(1)
    , _pThreadMgr(nullptr)
    , _clientId(TF_CLIENTID_NULL)
    , _activateFlags(0)
    , _pKeystrokeMgr(nullptr)
    , _pComposition(nullptr)
    , _composing(false)
    , _engineInitialized(false)
    , _shiftPressed(false)
{
    DllAddRef();
}

TextService::~TextService()
{
    DllRelease();
}

// IUnknown

STDMETHODIMP TextService::QueryInterface(REFIID riid, void **ppvObj)
{
    if (ppvObj == nullptr) return E_INVALIDARG;
    *ppvObj = nullptr;

    if (IsEqualIID(riid, IID_IUnknown) ||
        IsEqualIID(riid, IID_ITfTextInputProcessor) ||
        IsEqualIID(riid, IID_ITfTextInputProcessorEx)) {
        *ppvObj = static_cast<ITfTextInputProcessorEx *>(this);
    } else if (IsEqualIID(riid, IID_ITfKeyEventSink)) {
        *ppvObj = static_cast<ITfKeyEventSink *>(this);
    } else if (IsEqualIID(riid, IID_ITfCompositionSink)) {
        *ppvObj = static_cast<ITfCompositionSink *>(this);
    } else if (IsEqualIID(riid, IID_ITfDisplayAttributeProvider)) {
        *ppvObj = static_cast<ITfDisplayAttributeProvider *>(this);
    }

    if (*ppvObj) {
        AddRef();
        return S_OK;
    }

    return E_NOINTERFACE;
}

STDMETHODIMP_(ULONG) TextService::AddRef()
{
    return InterlockedIncrement(&_refCount);
}

STDMETHODIMP_(ULONG) TextService::Release()
{
    LONG count = InterlockedDecrement(&_refCount);
    if (count == 0) {
        delete this;
    }
    return count;
}

// ITfTextInputProcessor / ITfTextInputProcessorEx

STDMETHODIMP TextService::Activate(ITfThreadMgr *pThreadMgr, TfClientId tfClientId)
{
    return ActivateEx(pThreadMgr, tfClientId, 0);
}

STDMETHODIMP TextService::ActivateEx(ITfThreadMgr *pThreadMgr, TfClientId tfClientId, DWORD dwFlags)
{
    _pThreadMgr = pThreadMgr;
    _pThreadMgr->AddRef();
    _clientId = tfClientId;
    _activateFlags = dwFlags;

    // Initialize the Rust engine
    if (!InitEngine()) {
        // Engine init failure is not fatal; we just won't produce candidates
        OutputDebugStringW(L"HangeWubi: Engine initialization failed\n");
    }

    // Register as key event sink
    HRESULT hr = _pThreadMgr->QueryInterface(IID_ITfKeystrokeMgr, (void **)&_pKeystrokeMgr);
    if (SUCCEEDED(hr)) {
        hr = _pKeystrokeMgr->AdviseKeyEventSink(_clientId, static_cast<ITfKeyEventSink *>(this), TRUE);
        if (FAILED(hr)) {
            _pKeystrokeMgr->Release();
            _pKeystrokeMgr = nullptr;
        }
    }

    // Create candidate window
    _candidateWindow.Create(g_hInst);

    return S_OK;
}

STDMETHODIMP TextService::Deactivate()
{
    // Unadvise key event sink
    if (_pKeystrokeMgr) {
        _pKeystrokeMgr->UnadviseKeyEventSink(_clientId);
        _pKeystrokeMgr->Release();
        _pKeystrokeMgr = nullptr;
    }

    // Destroy candidate window
    _candidateWindow.Destroy();

    // End any active composition
    if (_pComposition) {
        _pComposition->EndComposition(0);
        _pComposition->Release();
        _pComposition = nullptr;
    }
    _composing = false;

    if (_pThreadMgr) {
        _pThreadMgr->Release();
        _pThreadMgr = nullptr;
    }
    _clientId = TF_CLIENTID_NULL;

    return S_OK;
}

// ─────────────────────── Engine Init ───────────────────────

bool TextService::InitEngine()
{
    if (_engineInitialized) return true;

    // Find data directory relative to the DLL location
    wchar_t dllPath[MAX_PATH];
    GetModuleFileNameW(g_hInst, dllPath, MAX_PATH);

    // Remove filename, keep directory
    wchar_t *lastSlash = wcsrchr(dllPath, L'\\');
    if (lastSlash) *lastSlash = L'\0';

    // Build path to dict file: <dll_dir>\data\wubi86.txt
    wchar_t dictPath[MAX_PATH];
    swprintf(dictPath, MAX_PATH, L"%s\\data\\wubi86.txt", dllPath);

    // Build path to pinyin dict: <dll_dir>\data\pinyin.txt
    wchar_t pinyinPath[MAX_PATH];
    swprintf(pinyinPath, MAX_PATH, L"%s\\data\\pinyin.txt", dllPath);

    // Convert to UTF-8 for the C FFI
    std::string dictPathUtf8 = WideToUtf8(dictPath);
    std::string pinyinPathUtf8 = WideToUtf8(pinyinPath);

    // Check if pinyin dict exists
    DWORD pinyinAttr = GetFileAttributesW(pinyinPath);
    const char *pinyinPtr = (pinyinAttr != INVALID_FILE_ATTRIBUTES) ? pinyinPathUtf8.c_str() : nullptr;

    int64_t count = ffi_init_with_pinyin(dictPathUtf8.c_str(), pinyinPtr);
    if (count < 0) {
        // Try alternate location: <dll_dir>\wubi86.txt
        swprintf(dictPath, MAX_PATH, L"%s\\wubi86.txt", dllPath);
        dictPathUtf8 = WideToUtf8(dictPath);
        count = ffi_init(dictPathUtf8.c_str());
    }

    if (count >= 0) {
        _engineInitialized = true;
        // Apply default config; enable pinyin mixed input when pinyin dict is present
        bool pinyinMixed = (pinyinPtr != nullptr);
        ffi_set_config(
            /*auto_commit_unique_4*/ true,
            /*auto_commit_first_5*/ false,
            /*enter_key_action*/ 0,
            /*empty_code_action*/ 0,
            /*candidate_count*/ 5,
            pinyinMixed);
        wchar_t msg[160];
        swprintf(msg, 160, L"HangeWubi: Loaded %lld entries, pinyinMixed=%d\n",
                 (long long)count, pinyinMixed ? 1 : 0);
        OutputDebugStringW(msg);
        return true;
    }

    return false;
}

// ─────────────────────── ITfKeyEventSink ───────────────────────

STDMETHODIMP TextService::OnSetFocus(BOOL /*fForeground*/)
{
    return S_OK;
}

STDMETHODIMP TextService::OnTestKeyDown(ITfContext * /*pContext*/, WPARAM wParam, LPARAM /*lParam*/, BOOL *pfEaten)
{
    *pfEaten = ShouldEatKey(wParam) ? TRUE : FALSE;
    return S_OK;
}

STDMETHODIMP TextService::OnTestKeyUp(ITfContext * /*pContext*/, WPARAM wParam, LPARAM /*lParam*/, BOOL *pfEaten)
{
    // Only eat Shift key-up if we're tracking it for mode toggle
    if (wParam == VK_SHIFT || wParam == VK_LSHIFT || wParam == VK_RSHIFT) {
        *pfEaten = _shiftPressed ? TRUE : FALSE;
    } else {
        *pfEaten = FALSE;
    }
    return S_OK;
}

STDMETHODIMP TextService::OnKeyDown(ITfContext *pContext, WPARAM wParam, LPARAM /*lParam*/, HRESULT *phrSession)
{
    *phrSession = S_OK;

    // Shift tracking for mode toggle
    if (wParam == VK_SHIFT || wParam == VK_LSHIFT || wParam == VK_RSHIFT) {
        // Only set shift_pressed if no other modifiers are held
        SHORT ctrl = GetKeyState(VK_CONTROL);
        SHORT alt = GetKeyState(VK_MENU);
        if (!(ctrl & 0x8000) && !(alt & 0x8000)) {
            _shiftPressed = true;
        }
        return S_OK;
    }

    // Any non-shift key press cancels shift tracking
    _shiftPressed = false;

    if (!ShouldEatKey(wParam)) return S_FALSE;

    // Process the key via an edit session
    KeyEditSession *pSession = new (std::nothrow) KeyEditSession(this, pContext, wParam, false);
    if (pSession == nullptr) return E_OUTOFMEMORY;

    HRESULT hr;
    hr = pContext->RequestEditSession(_clientId, pSession, TF_ES_READWRITE | TF_ES_SYNC, phrSession);
    pSession->Release();

    return hr;
}

STDMETHODIMP TextService::OnKeyUp(ITfContext *pContext, WPARAM wParam, LPARAM /*lParam*/, HRESULT *phrSession)
{
    *phrSession = S_OK;

    // Handle Shift release for mode toggle
    if ((wParam == VK_SHIFT || wParam == VK_LSHIFT || wParam == VK_RSHIFT) && _shiftPressed) {
        _shiftPressed = false;

        // If there's content in the buffer, commit it as raw English
        char *buf = ffi_get_buffer();
        if (buf && buf[0] != '\0') {
            std::wstring wbuf = Utf8ToWide(buf);
            DoCommitText(pContext, wbuf.c_str());
        }
        if (buf) ffi_free_string(buf);

        // Clear engine buffer
        FfiResult r = ffi_handle_escape();
        if (r.text) ffi_free_string(r.text);

        // Toggle mode
        ffi_toggle_mode();
        HideUI();

        return S_OK;
    }

    _shiftPressed = false;
    return S_OK;
}

STDMETHODIMP TextService::OnPreservedKey(ITfContext * /*pContext*/, REFGUID /*rguid*/, BOOL *pfEaten)
{
    *pfEaten = FALSE;
    return S_OK;
}

// ─────────────────────── Key handling ───────────────────────

bool TextService::ShouldEatKey(WPARAM vKey)
{
    if (!_engineInitialized) return false;

    // Don't eat keys when Ctrl or Alt are held
    SHORT ctrl = GetKeyState(VK_CONTROL);
    SHORT alt = GetKeyState(VK_MENU);
    if ((ctrl & 0x8000) || (alt & 0x8000)) return false;

    uint8_t mode = ffi_get_mode();

    // In English mode, only eat Shift for toggle
    if (mode == 1) {
        // Still eat letters if composing (temporary English via buffer)
        if (_composing) {
            if ((vKey >= 'A' && vKey <= 'Z') || vKey == VK_BACK ||
                vKey == VK_ESCAPE || vKey == VK_RETURN || vKey == VK_SPACE) {
                return true;
            }
        }
        return false;
    }

    // Chinese mode: eat relevant keys
    if (vKey >= 'A' && vKey <= 'Z') return true;
    if (vKey >= '1' && vKey <= '9') {
        // Only eat number keys if composing
        return _composing;
    }
    if (vKey == VK_SPACE) return true;
    if (vKey == VK_BACK) return _composing;
    if (vKey == VK_ESCAPE) return _composing;
    if (vKey == VK_RETURN) return _composing;
    if (vKey == VK_OEM_1) return true;     // semicolon
    if (vKey == VK_OEM_7) return true;     // quote/apostrophe
    if (vKey == VK_OEM_PLUS) return _composing; // = / +
    if (vKey == VK_OEM_MINUS) return _composing;  // -

    // Punctuation keys in Chinese mode
    if (vKey == VK_OEM_COMMA || vKey == VK_OEM_PERIOD ||
        vKey == VK_OEM_2 || vKey == VK_OEM_3 ||
        vKey == VK_OEM_4 || vKey == VK_OEM_5 ||
        vKey == VK_OEM_6 || vKey == VK_OEM_102 ||
        vKey == '0') {
        return true;
    }

    return false;
}

bool TextService::HandleKey(ITfContext *pContext, WPARAM vKey)
{
    if (!_engineInitialized) return false;

    FfiResult result;

    // Determine the actual character based on virtual key + shift state
    bool shift = (GetKeyState(VK_SHIFT) & 0x8000) != 0;

    // Letter keys a-z / A-Z
    if (vKey >= 'A' && vKey <= 'Z') {
        char ch = shift ? (char)vKey : (char)(vKey + 32);  // uppercase or lowercase
        result = ffi_handle_key(ch);
        return HandleFfiResult(pContext, result);
    }

    // Number keys 1-9
    if (vKey >= '1' && vKey <= '9') {
        result = ffi_handle_number((uint8_t)(vKey - '0'));
        return HandleFfiResult(pContext, result);
    }

    // Space
    if (vKey == VK_SPACE) {
        result = ffi_handle_space();
        return HandleFfiResult(pContext, result);
    }

    // Backspace
    if (vKey == VK_BACK) {
        result = ffi_handle_backspace();
        return HandleFfiResult(pContext, result);
    }

    // Escape
    if (vKey == VK_ESCAPE) {
        result = ffi_handle_escape();
        return HandleFfiResult(pContext, result);
    }

    // Enter
    if (vKey == VK_RETURN) {
        result = ffi_handle_enter();
        return HandleFfiResult(pContext, result);
    }

    // Semicolon
    if (vKey == VK_OEM_1) {
        if (shift) {
            // Shift+; = colon, handle as punctuation
            result = ffi_handle_punctuation(':');
        } else {
            result = ffi_handle_semicolon();
        }
        return HandleFfiResult(pContext, result);
    }

    // Quote / apostrophe
    if (vKey == VK_OEM_7) {
        if (shift) {
            // Shift+' = double quote
            result = ffi_handle_punctuation('"');
        } else {
            result = ffi_handle_quote();
        }
        return HandleFfiResult(pContext, result);
    }

    // Page navigation: = / + → next page
    if (vKey == VK_OEM_PLUS) {
        result = ffi_next_page();
        return HandleFfiResult(pContext, result);
    }

    // Page navigation: - → prev page
    if (vKey == VK_OEM_MINUS) {
        result = ffi_prev_page();
        return HandleFfiResult(pContext, result);
    }

    // Other punctuation keys - translate VK to ASCII
    char punctChar = 0;
    if (vKey == VK_OEM_COMMA)  punctChar = shift ? '<' : ',';
    else if (vKey == VK_OEM_PERIOD) punctChar = shift ? '>' : '.';
    else if (vKey == VK_OEM_2)  punctChar = shift ? '?' : '/';
    else if (vKey == VK_OEM_3)  punctChar = shift ? '~' : '`';
    else if (vKey == VK_OEM_4)  punctChar = shift ? '{' : '[';
    else if (vKey == VK_OEM_5)  punctChar = shift ? '|' : '\\';
    else if (vKey == VK_OEM_6)  punctChar = shift ? '}' : ']';
    else if (vKey == '0')       punctChar = shift ? ')' : '0';

    if (punctChar != 0) {
        result = ffi_handle_punctuation(punctChar);
        return HandleFfiResult(pContext, result);
    }

    return false;
}

bool TextService::HandleFfiResult(ITfContext *pContext, FfiResult result)
{
    switch (result.action) {
    case FFI_ACTION_COMMIT:
        if (result.text) {
            std::wstring wtext = Utf8ToWide(result.text);
            ffi_free_string(result.text);

            if (!_composing) {
                DoStartComposition(pContext);
            }
            DoCommitText(pContext, wtext.c_str());
            _composing = false;
        }
        // After commit, there may still be buffer content (e.g., auto-commit with continuation)
        SyncUI(pContext);
        return true;

    case FFI_ACTION_UPDATE_CANDIDATES:
        if (result.text) ffi_free_string(result.text);
        if (!_composing) {
            DoStartComposition(pContext);
            _composing = true;
        }
        SyncUI(pContext);
        return true;

    case FFI_ACTION_RESET:
        if (result.text) ffi_free_string(result.text);
        if (_composing) {
            DoEndComposition(pContext);
            _composing = false;
        }
        HideUI();
        return true;

    case FFI_ACTION_UNHANDLED:
    default:
        if (result.text) ffi_free_string(result.text);
        return false;
    }
}

// ─────────────────────── UI Sync ───────────────────────

void TextService::SyncUI(ITfContext *pContext)
{
    // Update preedit text
    char *buf = ffi_get_buffer();
    if (buf && buf[0] != '\0') {
        std::wstring wbuf = Utf8ToWide(buf);
        if (_composing) {
            DoSetCompositionText(pContext, wbuf.c_str());
        }
    } else {
        if (_composing) {
            DoSetCompositionText(pContext, L"");
        }
    }
    if (buf) ffi_free_string(buf);

    // Update candidate window
    UpdateCandidateWindow(pContext);
}

void TextService::HideUI()
{
    _candidateWindow.Hide();
}

void TextService::UpdateCandidateWindow(ITfContext *pContext)
{
    char *buf = ffi_get_buffer();
    bool hasBuffer = (buf && buf[0] != '\0');
    std::wstring wbuf;
    if (hasBuffer) {
        wbuf = Utf8ToWide(buf);
    }
    if (buf) ffi_free_string(buf);

    FfiCandidateList clist = ffi_get_candidates();

    if (clist.count == 0 || !hasBuffer) {
        _candidateWindow.Hide();
        if (clist.candidates) ffi_free_candidate_list(clist);
        return;
    }

    std::vector<std::wstring> candidates;
    std::vector<std::wstring> codes;
    for (size_t i = 0; i < clist.count; i++) {
        candidates.push_back(Utf8ToWide(clist.candidates[i].text));
        if (clist.candidates[i].code) {
            codes.push_back(Utf8ToWide(clist.candidates[i].code));
        } else {
            codes.push_back(L"");
        }
    }
    ffi_free_candidate_list(clist);

    // TODO: get real page info from engine if available
    _candidateWindow.Update(candidates, codes, wbuf, 0, 1);

    // Position near caret
    POINT pt = GetCaretPosition(pContext);
    _candidateWindow.Show(pt);
}

POINT TextService::GetCaretPosition(ITfContext * /*pContext*/)
{
    // Try to get caret position from the system
    POINT pt = { 0, 0 };
    GUITHREADINFO gti = {};
    gti.cbSize = sizeof(GUITHREADINFO);
    if (GetGUIThreadInfo(0, &gti)) {
        pt.x = gti.rcCaret.left;
        pt.y = gti.rcCaret.bottom;
        // Convert from client coordinates of the focused window to screen
        if (gti.hwndCaret) {
            ClientToScreen(gti.hwndCaret, &pt);
        }
    }
    return pt;
}

// ─────────────────────── Composition Edit Sessions ───────────────────────

HRESULT TextService::DoStartComposition(ITfContext *pContext)
{
    TextEditSession *pSession = new (std::nothrow) TextEditSession(
        this, pContext, TextEditSession::ACTION_START_COMPOSITION);
    if (!pSession) return E_OUTOFMEMORY;

    HRESULT hrSession;
    HRESULT hr = pContext->RequestEditSession(_clientId, pSession,
        TF_ES_READWRITE | TF_ES_SYNC, &hrSession);
    pSession->Release();
    return SUCCEEDED(hr) ? hrSession : hr;
}

HRESULT TextService::DoSetCompositionText(ITfContext *pContext, const wchar_t *text)
{
    TextEditSession *pSession = new (std::nothrow) TextEditSession(
        this, pContext, TextEditSession::ACTION_SET_TEXT, text);
    if (!pSession) return E_OUTOFMEMORY;

    HRESULT hrSession;
    HRESULT hr = pContext->RequestEditSession(_clientId, pSession,
        TF_ES_READWRITE | TF_ES_SYNC, &hrSession);
    pSession->Release();
    return SUCCEEDED(hr) ? hrSession : hr;
}

HRESULT TextService::DoEndComposition(ITfContext *pContext)
{
    TextEditSession *pSession = new (std::nothrow) TextEditSession(
        this, pContext, TextEditSession::ACTION_END_COMPOSITION);
    if (!pSession) return E_OUTOFMEMORY;

    HRESULT hrSession;
    HRESULT hr = pContext->RequestEditSession(_clientId, pSession,
        TF_ES_READWRITE | TF_ES_SYNC, &hrSession);
    pSession->Release();
    return SUCCEEDED(hr) ? hrSession : hr;
}

HRESULT TextService::DoCommitText(ITfContext *pContext, const wchar_t *text)
{
    TextEditSession *pSession = new (std::nothrow) TextEditSession(
        this, pContext, TextEditSession::ACTION_COMMIT_TEXT, text);
    if (!pSession) return E_OUTOFMEMORY;

    HRESULT hrSession;
    HRESULT hr = pContext->RequestEditSession(_clientId, pSession,
        TF_ES_READWRITE | TF_ES_SYNC, &hrSession);
    pSession->Release();
    return SUCCEEDED(hr) ? hrSession : hr;
}

// ─────────────────────── ITfCompositionSink ───────────────────────

STDMETHODIMP TextService::OnCompositionTerminated(TfEditCookie /*ecWrite*/, ITfComposition *pComposition)
{
    // The composition was terminated externally (e.g., by the application)
    if (_pComposition == pComposition) {
        _pComposition->Release();
        _pComposition = nullptr;
        _composing = false;
    }

    // Reset engine state
    FfiResult r = ffi_handle_escape();
    if (r.text) ffi_free_string(r.text);
    HideUI();

    return S_OK;
}

// ─────────────────────── ITfDisplayAttributeProvider ───────────────────────

STDMETHODIMP TextService::EnumDisplayAttributeInfo(IEnumTfDisplayAttributeInfo ** /*ppEnum*/)
{
    // Not implementing custom display attributes for now
    return E_NOTIMPL;
}

STDMETHODIMP TextService::GetDisplayAttributeInfo(REFGUID /*guid*/, ITfDisplayAttributeInfo ** /*ppInfo*/)
{
    return E_NOTIMPL;
}

// ─────────────────────── UTF conversion ───────────────────────

std::wstring TextService::Utf8ToWide(const char *utf8)
{
    if (!utf8 || !*utf8) return L"";
    int len = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, nullptr, 0);
    if (len <= 0) return L"";
    std::wstring result(len - 1, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, utf8, -1, &result[0], len);
    return result;
}

std::string TextService::WideToUtf8(const wchar_t *wide)
{
    if (!wide || !*wide) return "";
    int len = WideCharToMultiByte(CP_UTF8, 0, wide, -1, nullptr, 0, nullptr, nullptr);
    if (len <= 0) return "";
    std::string result(len - 1, '\0');
    WideCharToMultiByte(CP_UTF8, 0, wide, -1, &result[0], len, nullptr, nullptr);
    return result;
}

// ─────────────────────── KeyEditSession ───────────────────────

KeyEditSession::KeyEditSession(TextService *pService, ITfContext *pContext,
                               WPARAM vKey, bool isKeyUp)
    : _refCount(1), _pService(pService), _pContext(pContext), _vKey(vKey), _isKeyUp(isKeyUp)
{
    _pService->AddRef();
    _pContext->AddRef();
}

KeyEditSession::~KeyEditSession()
{
    _pService->Release();
    _pContext->Release();
}

STDMETHODIMP KeyEditSession::QueryInterface(REFIID riid, void **ppvObj)
{
    if (IsEqualIID(riid, IID_IUnknown) || IsEqualIID(riid, IID_ITfEditSession)) {
        *ppvObj = static_cast<ITfEditSession *>(this);
        AddRef();
        return S_OK;
    }
    *ppvObj = nullptr;
    return E_NOINTERFACE;
}

STDMETHODIMP_(ULONG) KeyEditSession::AddRef()
{
    return InterlockedIncrement(&_refCount);
}

STDMETHODIMP_(ULONG) KeyEditSession::Release()
{
    LONG c = InterlockedDecrement(&_refCount);
    if (c == 0) delete this;
    return c;
}

STDMETHODIMP KeyEditSession::DoEditSession(TfEditCookie /*ec*/)
{
    _pService->HandleKey(_pContext, _vKey);
    return S_OK;
}

// ─────────────────────── TextEditSession ───────────────────────

TextEditSession::TextEditSession(TextService *pService, ITfContext *pContext,
                                 Action action, const wchar_t *text)
    : _refCount(1), _pService(pService), _pContext(pContext), _action(action)
{
    _pService->AddRef();
    _pContext->AddRef();
    if (text) _text = text;
}

TextEditSession::~TextEditSession()
{
    _pService->Release();
    _pContext->Release();
}

STDMETHODIMP TextEditSession::QueryInterface(REFIID riid, void **ppvObj)
{
    if (IsEqualIID(riid, IID_IUnknown) || IsEqualIID(riid, IID_ITfEditSession)) {
        *ppvObj = static_cast<ITfEditSession *>(this);
        AddRef();
        return S_OK;
    }
    *ppvObj = nullptr;
    return E_NOINTERFACE;
}

STDMETHODIMP_(ULONG) TextEditSession::AddRef()
{
    return InterlockedIncrement(&_refCount);
}

STDMETHODIMP_(ULONG) TextEditSession::Release()
{
    LONG c = InterlockedDecrement(&_refCount);
    if (c == 0) delete this;
    return c;
}

STDMETHODIMP TextEditSession::DoEditSession(TfEditCookie ec)
{
    switch (_action) {
    case ACTION_START_COMPOSITION: {
        ITfInsertAtSelection *pInsert = nullptr;
        HRESULT hr = _pContext->QueryInterface(IID_ITfInsertAtSelection, (void **)&pInsert);
        if (FAILED(hr)) return hr;

        ITfRange *pRange = nullptr;
        hr = pInsert->InsertTextAtSelection(ec, TF_IAS_QUERYONLY, nullptr, 0, &pRange);
        pInsert->Release();
        if (FAILED(hr) || !pRange) return hr;

        ITfContextComposition *pCC = nullptr;
        hr = _pContext->QueryInterface(IID_ITfContextComposition, (void **)&pCC);
        if (FAILED(hr)) { pRange->Release(); return hr; }

        ITfComposition *pComp = nullptr;
        hr = pCC->StartComposition(ec, pRange, static_cast<ITfCompositionSink *>(_pService), &pComp);
        pCC->Release();
        pRange->Release();

        if (SUCCEEDED(hr) && pComp) {
            // Store the composition pointer in the service
            // Access through friend or public method - using a cast for now
            // since _pComposition is private. We'll set it via the public handle.
            _pService->_pComposition = pComp;
        }
        return hr;
    }

    case ACTION_SET_TEXT: {
        if (!_pService->_pComposition) return E_UNEXPECTED;
        ITfRange *pRange = nullptr;
        HRESULT hr = _pService->_pComposition->GetRange(&pRange);
        if (FAILED(hr) || !pRange) return hr;

        hr = pRange->SetText(ec, 0, _text.c_str(), (LONG)_text.length());
        pRange->Release();
        return hr;
    }

    case ACTION_COMMIT_TEXT: {
        if (!_pService->_pComposition) {
            // Start composition first, then commit
            ITfInsertAtSelection *pInsert = nullptr;
            HRESULT hr = _pContext->QueryInterface(IID_ITfInsertAtSelection, (void **)&pInsert);
            if (FAILED(hr)) return hr;

            ITfRange *pRange = nullptr;
            hr = pInsert->InsertTextAtSelection(ec, TF_IAS_QUERYONLY, nullptr, 0, &pRange);
            pInsert->Release();
            if (FAILED(hr) || !pRange) return hr;

            // Just insert text directly
            hr = pRange->SetText(ec, 0, _text.c_str(), (LONG)_text.length());
            pRange->Release();
            return hr;
        }

        ITfRange *pRange = nullptr;
        HRESULT hr = _pService->_pComposition->GetRange(&pRange);
        if (FAILED(hr) || !pRange) return hr;

        hr = pRange->SetText(ec, 0, _text.c_str(), (LONG)_text.length());
        if (SUCCEEDED(hr)) {
            _pService->_pComposition->EndComposition(ec);
            _pService->_pComposition->Release();
            _pService->_pComposition = nullptr;
        }
        pRange->Release();
        return hr;
    }

    case ACTION_END_COMPOSITION: {
        if (_pService->_pComposition) {
            // Clear the composition text first
            ITfRange *pRange = nullptr;
            HRESULT hr = _pService->_pComposition->GetRange(&pRange);
            if (SUCCEEDED(hr) && pRange) {
                pRange->SetText(ec, 0, L"", 0);
                pRange->Release();
            }
            _pService->_pComposition->EndComposition(ec);
            _pService->_pComposition->Release();
            _pService->_pComposition = nullptr;
        }
        return S_OK;
    }
    }

    return E_UNEXPECTED;
}
