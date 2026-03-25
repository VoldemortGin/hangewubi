#ifndef HANGEWUBI_TSF_CLASS_FACTORY_H
#define HANGEWUBI_TSF_CLASS_FACTORY_H

#include "globals.h"

class ClassFactory : public IClassFactory {
public:
    // IUnknown
    STDMETHODIMP QueryInterface(REFIID riid, void **ppvObj);
    STDMETHODIMP_(ULONG) AddRef();
    STDMETHODIMP_(ULONG) Release();

    // IClassFactory
    STDMETHODIMP CreateInstance(IUnknown *pUnkOuter, REFIID riid, void **ppvObj);
    STDMETHODIMP LockServer(BOOL fLock);

    ClassFactory();

private:
    ~ClassFactory();
    LONG _refCount;
};

#endif // HANGEWUBI_TSF_CLASS_FACTORY_H
