#include "class_factory.h"
#include "text_service.h"
#include <new>

ClassFactory::ClassFactory()
    : _refCount(1)
{
    DllAddRef();
}

ClassFactory::~ClassFactory()
{
    DllRelease();
}

// IUnknown

STDMETHODIMP ClassFactory::QueryInterface(REFIID riid, void **ppvObj)
{
    if (ppvObj == nullptr) return E_INVALIDARG;

    *ppvObj = nullptr;

    if (IsEqualIID(riid, IID_IUnknown) || IsEqualIID(riid, IID_IClassFactory)) {
        *ppvObj = static_cast<IClassFactory *>(this);
        AddRef();
        return S_OK;
    }

    return E_NOINTERFACE;
}

STDMETHODIMP_(ULONG) ClassFactory::AddRef()
{
    return InterlockedIncrement(&_refCount);
}

STDMETHODIMP_(ULONG) ClassFactory::Release()
{
    LONG count = InterlockedDecrement(&_refCount);
    if (count == 0) {
        delete this;
    }
    return count;
}

// IClassFactory

STDMETHODIMP ClassFactory::CreateInstance(IUnknown *pUnkOuter, REFIID riid, void **ppvObj)
{
    if (ppvObj == nullptr) return E_INVALIDARG;
    *ppvObj = nullptr;

    if (pUnkOuter != nullptr) return CLASS_E_NOAGGREGATION;

    TextService *pService = new (std::nothrow) TextService();
    if (pService == nullptr) return E_OUTOFMEMORY;

    HRESULT hr = pService->QueryInterface(riid, ppvObj);
    pService->Release();  // QI added a ref if successful
    return hr;
}

STDMETHODIMP ClassFactory::LockServer(BOOL fLock)
{
    if (fLock) {
        DllAddRef();
    } else {
        DllRelease();
    }
    return S_OK;
}
