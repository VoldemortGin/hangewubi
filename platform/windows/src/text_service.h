#ifndef HANGEWUBI_TSF_TEXT_SERVICE_H
#define HANGEWUBI_TSF_TEXT_SERVICE_H

#include "globals.h"
#include "composition.h"
#include "candidate_list.h"
#include "hangewubi.h"

#include <string>

class TextService : public ITfTextInputProcessorEx,
                    public ITfKeyEventSink,
                    public ITfCompositionSink,
                    public ITfDisplayAttributeProvider {
public:
    TextService();

    // IUnknown
    STDMETHODIMP QueryInterface(REFIID riid, void **ppvObj);
    STDMETHODIMP_(ULONG) AddRef();
    STDMETHODIMP_(ULONG) Release();

    // ITfTextInputProcessor
    STDMETHODIMP Activate(ITfThreadMgr *pThreadMgr, TfClientId tfClientId);
    STDMETHODIMP Deactivate();

    // ITfTextInputProcessorEx
    STDMETHODIMP ActivateEx(ITfThreadMgr *pThreadMgr, TfClientId tfClientId, DWORD dwFlags);

    // ITfKeyEventSink
    STDMETHODIMP OnSetFocus(BOOL fForeground);
    STDMETHODIMP OnTestKeyDown(ITfContext *pContext, WPARAM wParam, LPARAM lParam, BOOL *pfEaten);
    STDMETHODIMP OnTestKeyUp(ITfContext *pContext, WPARAM wParam, LPARAM lParam, BOOL *pfEaten);
    STDMETHODIMP OnKeyDown(ITfContext *pContext, WPARAM wParam, LPARAM lParam, HRESULT *phrSession);
    STDMETHODIMP OnKeyUp(ITfContext *pContext, WPARAM wParam, LPARAM lParam, HRESULT *phrSession);
    STDMETHODIMP OnPreservedKey(ITfContext *pContext, REFGUID rguid, BOOL *pfEaten);

    // ITfCompositionSink
    STDMETHODIMP OnCompositionTerminated(TfEditCookie ecWrite, ITfComposition *pComposition);

    // ITfDisplayAttributeProvider
    STDMETHODIMP EnumDisplayAttributeInfo(IEnumTfDisplayAttributeInfo **ppEnum);
    STDMETHODIMP GetDisplayAttributeInfo(REFGUID guid, ITfDisplayAttributeInfo **ppInfo);

    // Accessors
    TfClientId GetClientId() const { return _clientId; }
    ITfThreadMgr *GetThreadMgr() const { return _pThreadMgr; }

private:
    friend class TextEditSession;
    friend class KeyEditSession;

    ~TextService();

    // Initialize the Rust engine
    bool InitEngine();

    // Key handling helpers
    bool HandleKey(ITfContext *pContext, WPARAM vKey);
    bool ShouldEatKey(WPARAM vKey);

    // FFI result handling
    bool HandleFfiResult(ITfContext *pContext, FfiResult result);

    // UI update helpers
    void SyncUI(ITfContext *pContext);
    void HideUI();
    void UpdateCandidateWindow(ITfContext *pContext);
    POINT GetCaretPosition(ITfContext *pContext);

    // Edit session for composition operations
    HRESULT DoStartComposition(ITfContext *pContext);
    HRESULT DoSetCompositionText(ITfContext *pContext, const wchar_t *text);
    HRESULT DoEndComposition(ITfContext *pContext);
    HRESULT DoCommitText(ITfContext *pContext, const wchar_t *text);

    // UTF-8 <-> UTF-16 conversion
    static std::wstring Utf8ToWide(const char *utf8);
    static std::string WideToUtf8(const wchar_t *wide);

    LONG _refCount;
    ITfThreadMgr *_pThreadMgr;
    TfClientId _clientId;
    DWORD _activateFlags;
    ITfKeystrokeMgr *_pKeystrokeMgr;

    // Composition state
    ITfComposition *_pComposition;
    bool _composing;

    // Candidate window
    CandidateWindow _candidateWindow;

    // Engine state
    bool _engineInitialized;

    // Shift tracking for mode toggle
    bool _shiftPressed;
};

// Edit session helper class used by TextService for synchronous edits
class KeyEditSession : public ITfEditSession {
public:
    KeyEditSession(TextService *pService, ITfContext *pContext,
                   WPARAM vKey, bool isKeyUp);

    // IUnknown
    STDMETHODIMP QueryInterface(REFIID riid, void **ppvObj);
    STDMETHODIMP_(ULONG) AddRef();
    STDMETHODIMP_(ULONG) Release();

    // ITfEditSession
    STDMETHODIMP DoEditSession(TfEditCookie ec);

private:
    ~KeyEditSession();

    LONG _refCount;
    TextService *_pService;
    ITfContext *_pContext;
    WPARAM _vKey;
    bool _isKeyUp;
};

// Edit session for committing/setting text
class TextEditSession : public ITfEditSession {
public:
    enum Action {
        ACTION_START_COMPOSITION,
        ACTION_SET_TEXT,
        ACTION_COMMIT_TEXT,
        ACTION_END_COMPOSITION,
    };

    TextEditSession(TextService *pService, ITfContext *pContext,
                    Action action, const wchar_t *text = nullptr);

    // IUnknown
    STDMETHODIMP QueryInterface(REFIID riid, void **ppvObj);
    STDMETHODIMP_(ULONG) AddRef();
    STDMETHODIMP_(ULONG) Release();

    // ITfEditSession
    STDMETHODIMP DoEditSession(TfEditCookie ec);

private:
    ~TextEditSession();

    LONG _refCount;
    TextService *_pService;
    ITfContext *_pContext;
    Action _action;
    std::wstring _text;
};

#endif // HANGEWUBI_TSF_TEXT_SERVICE_H
