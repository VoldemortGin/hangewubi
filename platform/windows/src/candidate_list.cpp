#include "candidate_list.h"
#include <cstdio>

static const wchar_t *CANDIDATE_WND_CLASS = L"HangeWubiCandidateWindow";

CandidateWindow::CandidateWindow()
    : _hwnd(nullptr)
    , _hInst(nullptr)
    , _registered(false)
    , _currentPage(0)
    , _totalPages(0)
    , _hFont(nullptr)
{
}

CandidateWindow::~CandidateWindow()
{
    Destroy();
}

HRESULT CandidateWindow::Create(HINSTANCE hInst)
{
    _hInst = hInst;

    if (!_registered) {
        WNDCLASSEXW wc = {};
        wc.cbSize        = sizeof(WNDCLASSEXW);
        wc.style         = CS_HREDRAW | CS_VREDRAW;
        wc.lpfnWndProc   = CandidateWindow::WndProc;
        wc.cbClsExtra    = 0;
        wc.cbWndExtra    = sizeof(LONG_PTR);  // store 'this' pointer
        wc.hInstance     = hInst;
        wc.hCursor       = LoadCursor(nullptr, IDC_ARROW);
        wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
        wc.lpszClassName = CANDIDATE_WND_CLASS;

        if (RegisterClassExW(&wc) == 0 && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
            return E_FAIL;
        }
        _registered = true;
    }

    _hwnd = CreateWindowExW(
        WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
        CANDIDATE_WND_CLASS,
        L"",
        WS_POPUP | WS_BORDER,
        0, 0, 300, 200,
        nullptr, nullptr, hInst, nullptr);

    if (_hwnd == nullptr) return E_FAIL;

    // Store 'this' pointer in window extra data
    SetWindowLongPtrW(_hwnd, 0, reinterpret_cast<LONG_PTR>(this));

    // Create font for candidate display
    _hFont = CreateFontW(
        FONT_SIZE, 0, 0, 0,
        FW_NORMAL, FALSE, FALSE, FALSE,
        DEFAULT_CHARSET,
        OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
        CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_DONTCARE,
        L"Microsoft YaHei");

    if (_hFont == nullptr) {
        _hFont = CreateFontW(
            FONT_SIZE, 0, 0, 0,
            FW_NORMAL, FALSE, FALSE, FALSE,
            DEFAULT_CHARSET,
            OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
            CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_DONTCARE,
            L"SimSun");
    }

    return S_OK;
}

void CandidateWindow::Destroy()
{
    if (_hwnd) {
        DestroyWindow(_hwnd);
        _hwnd = nullptr;
    }
    if (_hFont) {
        DeleteObject(_hFont);
        _hFont = nullptr;
    }
}

void CandidateWindow::Update(
    const std::vector<std::wstring> &candidates,
    const std::vector<std::wstring> &codes,
    const std::wstring &buffer,
    int currentPage, int totalPages)
{
    _candidates = candidates;
    _codes = codes;
    _buffer = buffer;
    _currentPage = currentPage;
    _totalPages = totalPages;

    if (_hwnd == nullptr) return;

    // Calculate window size
    int count = (int)_candidates.size();
    if (count == 0) {
        Hide();
        return;
    }

    // Measure text to determine width
    HDC hdc = GetDC(_hwnd);
    HFONT hOldFont = (HFONT)SelectObject(hdc, _hFont);

    int maxWidth = 100;  // minimum width
    for (int i = 0; i < count; i++) {
        // Format: "1.候选 编码"
        wchar_t line[256];
        if (i < (int)_codes.size() && !_codes[i].empty()) {
            swprintf(line, 256, L"%d.%s  %s", i + 1, _candidates[i].c_str(), _codes[i].c_str());
        } else {
            swprintf(line, 256, L"%d.%s", i + 1, _candidates[i].c_str());
        }
        SIZE sz;
        GetTextExtentPoint32W(hdc, line, (int)wcslen(line), &sz);
        if (sz.cx + PADDING * 4 > maxWidth) {
            maxWidth = sz.cx + PADDING * 4;
        }
    }

    SelectObject(hdc, hOldFont);
    ReleaseDC(_hwnd, hdc);

    // Buffer line at top + candidate items + optional page indicator
    int totalHeight = PADDING + ITEM_HEIGHT;  // buffer line
    totalHeight += count * ITEM_HEIGHT;
    if (_totalPages > 1) {
        totalHeight += ITEM_HEIGHT;  // page indicator
    }
    totalHeight += PADDING;

    SetWindowPos(_hwnd, HWND_TOPMOST, 0, 0,
                 maxWidth, totalHeight,
                 SWP_NOMOVE | SWP_NOACTIVATE);

    InvalidateRect(_hwnd, nullptr, TRUE);
}

void CandidateWindow::Hide()
{
    if (_hwnd) {
        ShowWindow(_hwnd, SW_HIDE);
    }
    _candidates.clear();
    _codes.clear();
}

void CandidateWindow::Show(POINT pt)
{
    if (_hwnd == nullptr || _candidates.empty()) return;

    // Get screen dimensions to avoid going off-screen
    RECT rcWork;
    SystemParametersInfoW(SPI_GETWORKAREA, 0, &rcWork, 0);

    RECT rcWnd;
    GetWindowRect(_hwnd, &rcWnd);
    int wndW = rcWnd.right - rcWnd.left;
    int wndH = rcWnd.bottom - rcWnd.top;

    int x = pt.x;
    int y = pt.y + 20;  // below the caret

    if (x + wndW > rcWork.right) x = rcWork.right - wndW;
    if (y + wndH > rcWork.bottom) y = pt.y - wndH;  // show above if no room below
    if (x < rcWork.left) x = rcWork.left;
    if (y < rcWork.top) y = rcWork.top;

    SetWindowPos(_hwnd, HWND_TOPMOST, x, y, 0, 0,
                 SWP_NOSIZE | SWP_NOACTIVATE);
    ShowWindow(_hwnd, SW_SHOWNOACTIVATE);
}

bool CandidateWindow::IsVisible() const
{
    return _hwnd && IsWindowVisible(_hwnd);
}

LRESULT CALLBACK CandidateWindow::WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam)
{
    switch (msg) {
    case WM_PAINT: {
        CandidateWindow *pThis = reinterpret_cast<CandidateWindow *>(
            GetWindowLongPtrW(hwnd, 0));
        if (pThis) {
            PAINTSTRUCT ps;
            HDC hdc = BeginPaint(hwnd, &ps);
            pThis->OnPaint(hdc);
            EndPaint(hwnd, &ps);
            return 0;
        }
        break;
    }
    case WM_ERASEBKGND:
        return 1;  // we handle background in OnPaint
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam);
}

void CandidateWindow::OnPaint(HDC hdc)
{
    RECT rcClient;
    GetClientRect(_hwnd, &rcClient);

    // Fill background
    HBRUSH hBrush = CreateSolidBrush(RGB(255, 255, 255));
    FillRect(hdc, &rcClient, hBrush);
    DeleteObject(hBrush);

    HFONT hOldFont = (HFONT)SelectObject(hdc, _hFont);
    SetBkMode(hdc, TRANSPARENT);

    int y = PADDING;

    // Draw buffer (preedit) text
    if (!_buffer.empty()) {
        SetTextColor(hdc, RGB(0, 0, 180));
        RECT rcBuf = { PADDING, y, rcClient.right - PADDING, y + ITEM_HEIGHT };
        DrawTextW(hdc, _buffer.c_str(), (int)_buffer.length(), &rcBuf, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
    }
    y += ITEM_HEIGHT;

    // Draw separator
    HPEN hPen = CreatePen(PS_SOLID, 1, RGB(200, 200, 200));
    HPEN hOldPen = (HPEN)SelectObject(hdc, hPen);
    MoveToEx(hdc, PADDING, y, nullptr);
    LineTo(hdc, rcClient.right - PADDING, y);
    SelectObject(hdc, hOldPen);
    DeleteObject(hPen);

    // Draw candidates
    SetTextColor(hdc, RGB(0, 0, 0));
    for (int i = 0; i < (int)_candidates.size(); i++) {
        wchar_t line[256];
        if (i < (int)_codes.size() && !_codes[i].empty()) {
            swprintf(line, 256, L"%d.%s  ", i + 1, _candidates[i].c_str());
        } else {
            swprintf(line, 256, L"%d.%s", i + 1, _candidates[i].c_str());
        }

        RECT rcItem = { PADDING * 2, y, rcClient.right - PADDING, y + ITEM_HEIGHT };

        // Draw the candidate text
        SetTextColor(hdc, RGB(0, 0, 0));
        DrawTextW(hdc, line, (int)wcslen(line), &rcItem, DT_LEFT | DT_VCENTER | DT_SINGLELINE);

        // Draw the code in gray after the candidate
        if (i < (int)_codes.size() && !_codes[i].empty()) {
            SIZE sz;
            GetTextExtentPoint32W(hdc, line, (int)wcslen(line), &sz);
            RECT rcCode = { PADDING * 2 + sz.cx, y, rcClient.right - PADDING, y + ITEM_HEIGHT };
            SetTextColor(hdc, RGB(150, 150, 150));
            DrawTextW(hdc, _codes[i].c_str(), (int)_codes[i].length(), &rcCode, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
        }

        y += ITEM_HEIGHT;
    }

    // Draw page indicator
    if (_totalPages > 1) {
        wchar_t pageStr[32];
        swprintf(pageStr, 32, L"%d/%d", _currentPage + 1, _totalPages);
        SetTextColor(hdc, RGB(128, 128, 128));
        RECT rcPage = { PADDING, y, rcClient.right - PADDING, y + ITEM_HEIGHT };
        DrawTextW(hdc, pageStr, (int)wcslen(pageStr), &rcPage, DT_RIGHT | DT_VCENTER | DT_SINGLELINE);
    }

    SelectObject(hdc, hOldFont);
}
