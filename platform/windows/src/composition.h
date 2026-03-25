#ifndef HANGEWUBI_TSF_COMPOSITION_H
#define HANGEWUBI_TSF_COMPOSITION_H

#include "globals.h"

class TextService;

// Helper class for managing TSF composition (preedit text)
class CompositionManager {
public:
    CompositionManager();
    ~CompositionManager();

    // Start a new composition at the current insertion point
    HRESULT StartComposition(ITfContext *pContext, TextService *pService);

    // End the current composition
    HRESULT EndComposition();

    // Set the composition/preedit text (with underline attribute)
    HRESULT SetCompositionText(const wchar_t *text);

    // Commit final text: replaces composition range with committed text, then ends composition
    HRESULT CommitText(const wchar_t *text);

    // Check if a composition is active
    bool IsComposing() const { return _pComposition != nullptr; }

    ITfComposition *GetComposition() const { return _pComposition; }

private:
    ITfComposition *_pComposition;
    ITfContext *_pContext;
    TfEditCookie _editCookie;
};

#endif // HANGEWUBI_TSF_COMPOSITION_H
