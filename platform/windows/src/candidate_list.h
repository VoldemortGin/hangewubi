#ifndef HANGEWUBI_TSF_CANDIDATE_LIST_H
#define HANGEWUBI_TSF_CANDIDATE_LIST_H

#include "globals.h"
#include <string>
#include <vector>

class TextService;

// Candidate window implemented as a simple popup window.
// TSF's ITfCandidateListUIElement is complex and poorly documented,
// so we use a lightweight HWND-based approach like most Chinese IMEs.
class CandidateWindow {
public:
    CandidateWindow();
    ~CandidateWindow();

    // Initialize the window class and create the popup
    HRESULT Create(HINSTANCE hInst);

    // Destroy the window
    void Destroy();

    // Update candidates and show/reposition the window near the caret
    void Update(const std::vector<std::wstring> &candidates,
                const std::vector<std::wstring> &codes,
                const std::wstring &buffer,
                int currentPage, int totalPages);

    // Hide the candidate window
    void Hide();

    // Show the candidate window near a given screen position
    void Show(POINT pt);

    // Check if visible
    bool IsVisible() const;

    // Get the HWND
    HWND GetHwnd() const { return _hwnd; }

private:
    static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam);
    void OnPaint(HDC hdc);

    HWND _hwnd;
    HINSTANCE _hInst;
    bool _registered;

    // Current display data
    std::vector<std::wstring> _candidates;
    std::vector<std::wstring> _codes;
    std::wstring _buffer;
    int _currentPage;
    int _totalPages;

    // UI constants
    static const int PADDING = 4;
    static const int ITEM_HEIGHT = 24;
    static const int FONT_SIZE = 16;
    HFONT _hFont;
};

#endif // HANGEWUBI_TSF_CANDIDATE_LIST_H
