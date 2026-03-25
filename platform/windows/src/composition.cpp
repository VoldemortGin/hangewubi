#include "composition.h"
#include "text_service.h"
#include <string>

CompositionManager::CompositionManager()
    : _pComposition(nullptr)
    , _pContext(nullptr)
    , _editCookie(0)
{
}

CompositionManager::~CompositionManager()
{
    EndComposition();
}

// EditSession for starting composition
class StartCompositionEditSession : public ITfEditSession {
public:
    StartCompositionEditSession(ITfContext *pContext, TextService *pService, CompositionManager *pMgr)
        : _refCount(1), _pContext(pContext), _pService(pService), _pMgr(pMgr)
    {
        _pContext->AddRef();
    }

    ~StartCompositionEditSession() {
        _pContext->Release();
    }

    // IUnknown
    STDMETHODIMP QueryInterface(REFIID riid, void **ppvObj) {
        if (IsEqualIID(riid, IID_IUnknown) || IsEqualIID(riid, IID_ITfEditSession)) {
            *ppvObj = static_cast<ITfEditSession *>(this);
            AddRef();
            return S_OK;
        }
        *ppvObj = nullptr;
        return E_NOINTERFACE;
    }
    STDMETHODIMP_(ULONG) AddRef() { return InterlockedIncrement(&_refCount); }
    STDMETHODIMP_(ULONG) Release() {
        LONG c = InterlockedDecrement(&_refCount);
        if (c == 0) delete this;
        return c;
    }

    // ITfEditSession
    STDMETHODIMP DoEditSession(TfEditCookie ec) {
        ITfInsertAtSelection *pInsert = nullptr;
        HRESULT hr = _pContext->QueryInterface(IID_ITfInsertAtSelection, (void **)&pInsert);
        if (FAILED(hr)) return hr;

        ITfRange *pRange = nullptr;
        hr = pInsert->InsertTextAtSelection(ec, TF_IAS_QUERYONLY, nullptr, 0, &pRange);
        pInsert->Release();
        if (FAILED(hr) || pRange == nullptr) return hr;

        ITfContextComposition *pContextComposition = nullptr;
        hr = _pContext->QueryInterface(IID_ITfContextComposition, (void **)&pContextComposition);
        if (FAILED(hr)) {
            pRange->Release();
            return hr;
        }

        ITfComposition *pComposition = nullptr;
        hr = pContextComposition->StartComposition(ec, pRange, static_cast<ITfCompositionSink *>(_pService), &pComposition);
        pContextComposition->Release();
        pRange->Release();

        if (SUCCEEDED(hr) && pComposition != nullptr) {
            _pMgr->_pComposition = pComposition;
            _pMgr->_pContext = _pContext;
            _pMgr->_pContext->AddRef();
            _pMgr->_editCookie = ec;
        }

        return hr;
    }

private:
    LONG _refCount;
    ITfContext *_pContext;
    TextService *_pService;
    CompositionManager *_pMgr;
    friend class CompositionManager;
};

HRESULT CompositionManager::StartComposition(ITfContext *pContext, TextService *pService)
{
    if (_pComposition != nullptr) return S_OK;  // already composing

    StartCompositionEditSession *pSession = new (std::nothrow) StartCompositionEditSession(pContext, pService, this);
    if (pSession == nullptr) return E_OUTOFMEMORY;

    HRESULT hr;
    HRESULT hrSession;
    hr = pContext->RequestEditSession(pService->GetClientId(), pSession, TF_ES_READWRITE | TF_ES_SYNC, &hrSession);
    pSession->Release();

    if (SUCCEEDED(hr)) hr = hrSession;
    return hr;
}

HRESULT CompositionManager::EndComposition()
{
    if (_pComposition == nullptr) return S_OK;

    // We need an edit session to end the composition properly,
    // but if context is gone we just release
    _pComposition->EndComposition(0);  // best-effort with cookie 0
    _pComposition->Release();
    _pComposition = nullptr;

    if (_pContext) {
        _pContext->Release();
        _pContext = nullptr;
    }

    return S_OK;
}

// EditSession for setting text in composition
class SetTextEditSession : public ITfEditSession {
public:
    SetTextEditSession(ITfContext *pContext, ITfComposition *pComposition,
                       const wchar_t *text, bool commit, TfClientId clientId)
        : _refCount(1), _pContext(pContext), _pComposition(pComposition)
        , _text(text), _commit(commit), _clientId(clientId)
    {
        _pContext->AddRef();
        _pComposition->AddRef();
    }

    ~SetTextEditSession() {
        _pContext->Release();
        _pComposition->Release();
    }

    // IUnknown
    STDMETHODIMP QueryInterface(REFIID riid, void **ppvObj) {
        if (IsEqualIID(riid, IID_IUnknown) || IsEqualIID(riid, IID_ITfEditSession)) {
            *ppvObj = static_cast<ITfEditSession *>(this);
            AddRef();
            return S_OK;
        }
        *ppvObj = nullptr;
        return E_NOINTERFACE;
    }
    STDMETHODIMP_(ULONG) AddRef() { return InterlockedIncrement(&_refCount); }
    STDMETHODIMP_(ULONG) Release() {
        LONG c = InterlockedDecrement(&_refCount);
        if (c == 0) delete this;
        return c;
    }

    // ITfEditSession
    STDMETHODIMP DoEditSession(TfEditCookie ec) {
        ITfRange *pRange = nullptr;
        HRESULT hr = _pComposition->GetRange(&pRange);
        if (FAILED(hr) || pRange == nullptr) return hr;

        hr = pRange->SetText(ec, 0, _text.c_str(), (LONG)_text.length());

        if (SUCCEEDED(hr) && !_commit) {
            // Set display attribute: underline for preedit
            ITfProperty *pProp = nullptr;
            hr = _pContext->GetProperty(GUID_PROP_ATTRIBUTE, &pProp);
            // We skip display attribute setting for simplicity;
            // the composition range itself provides visual feedback.
            if (pProp) pProp->Release();
        }

        if (SUCCEEDED(hr) && _commit) {
            _pComposition->EndComposition(ec);
        }

        pRange->Release();
        return hr;
    }

private:
    LONG _refCount;
    ITfContext *_pContext;
    ITfComposition *_pComposition;
    std::wstring _text;
    bool _commit;
    TfClientId _clientId;
};

HRESULT CompositionManager::SetCompositionText(const wchar_t *text)
{
    if (_pComposition == nullptr || _pContext == nullptr) return E_UNEXPECTED;

    // We need a way to get the client ID. Store it from the TextService.
    // For now, we do a synchronous edit session.
    // The caller (TextService) will use its own edit session approach.
    // This function is a convenience wrapper used within edit sessions.

    ITfRange *pRange = nullptr;
    HRESULT hr = _pComposition->GetRange(&pRange);
    if (FAILED(hr) || pRange == nullptr) return hr;

    hr = pRange->SetText(_editCookie, 0, text, (LONG)wcslen(text));
    pRange->Release();
    return hr;
}

HRESULT CompositionManager::CommitText(const wchar_t *text)
{
    if (_pComposition == nullptr || _pContext == nullptr) return E_UNEXPECTED;

    ITfRange *pRange = nullptr;
    HRESULT hr = _pComposition->GetRange(&pRange);
    if (FAILED(hr) || pRange == nullptr) return hr;

    hr = pRange->SetText(_editCookie, 0, text, (LONG)wcslen(text));
    if (SUCCEEDED(hr)) {
        _pComposition->EndComposition(_editCookie);
        _pComposition->Release();
        _pComposition = nullptr;
        _pContext->Release();
        _pContext = nullptr;
    }

    pRange->Release();
    return hr;
}
