// The candidate list: a small topmost popup under the composition that never takes focus.
#include "tsf.h"

#include <windowsx.h>

static const wchar_t kClass[] = L"AutoZhuyinCandidates";
static const int kPad = 6;
static const UINT_PTR kFlashTimer = 1;

void CandidateWindow::RegisterWindowClass() {
    WNDCLASSEXW wc = {sizeof(wc)};
    wc.style = CS_IME | CS_DROPSHADOW;
    wc.lpfnWndProc = WndProc;
    wc.hInstance = g_hInstance;
    wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
    wc.lpszClassName = kClass;
    RegisterClassExW(&wc);
}

void CandidateWindow::UnregisterWindowClass() { UnregisterClassW(kClass, g_hInstance); }

CandidateWindow::~CandidateWindow() {
    if (hwnd_) DestroyWindow(hwnd_);
    if (font_) DeleteObject(font_);
}

void CandidateWindow::Ensure() {
    if (hwnd_) return;
    hwnd_ = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, kClass, L"", WS_POPUP | WS_BORDER,
                            0, 0, 10, 10, nullptr, nullptr, g_hInstance, nullptr);
    SetWindowLongPtrW(hwnd_, GWLP_USERDATA, (LONG_PTR)this);
    UINT dpi = GetDpiForWindow(hwnd_);
    font_ = CreateFontW(-MulDiv(12, dpi ? dpi : 96, 72), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, DEFAULT_CHARSET,
                        OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH,
                        L"Microsoft JhengHei UI");
}

HWND CandidateWindow::Handle() {
    Ensure();
    return hwnd_;
}

void CandidateWindow::Show(const std::vector<std::wstring>& items, int selected, const RECT& textRect) {
    Ensure();
    KillTimer(hwnd_, kFlashTimer);
    items_ = items;
    selected_ = selected;
    numbered_ = true;
    Layout(textRect);
}

void CandidateWindow::Flash(const std::wstring& text, const RECT& textRect) {
    Ensure();
    items_ = {text};
    selected_ = -1;
    numbered_ = false;
    Layout(textRect);
    SetTimer(hwnd_, kFlashTimer, 800, nullptr);
}

void CandidateWindow::Hide() {
    if (hwnd_) ShowWindow(hwnd_, SW_HIDE);
}

void CandidateWindow::Layout(const RECT& textRect) {
    HDC dc = GetDC(hwnd_);
    HGDIOBJ old = SelectObject(dc, font_);
    int width = 0;
    TEXTMETRICW tm;
    GetTextMetricsW(dc, &tm);
    rowHeight_ = tm.tmHeight + 4;
    for (size_t i = 0; i < items_.size(); i++) {
        std::wstring row = numbered_ ? std::to_wstring(i + 1) + L". " + items_[i] : items_[i];
        SIZE size;
        GetTextExtentPoint32W(dc, row.c_str(), (int)row.size(), &size);
        if (size.cx > width) width = size.cx;
    }
    SelectObject(dc, old);
    ReleaseDC(hwnd_, dc);

    int w = width + kPad * 2 + 2, h = rowHeight_ * (int)items_.size() + kPad * 2 + 2;
    POINT pt = {textRect.left, textRect.bottom + 2};
    MONITORINFO mi = {sizeof(mi)};
    if (GetMonitorInfoW(MonitorFromPoint(pt, MONITOR_DEFAULTTONEAREST), &mi)) {
        RECT work = mi.rcWork;
        if (pt.y + h > work.bottom) pt.y = textRect.top - h - 2;   // no room below: above the text
        if (pt.x + w > work.right) pt.x = work.right - w;
        if (pt.x < work.left) pt.x = work.left;
        if (pt.y < work.top) pt.y = work.top;
    }
    SetWindowPos(hwnd_, HWND_TOPMOST, pt.x, pt.y, w, h, SWP_NOACTIVATE | SWP_SHOWWINDOW);
    InvalidateRect(hwnd_, nullptr, TRUE);
}

void CandidateWindow::Paint(HDC dc) {
    RECT rc;
    GetClientRect(hwnd_, &rc);
    FillRect(dc, &rc, GetSysColorBrush(COLOR_WINDOW));
    HGDIOBJ old = SelectObject(dc, font_);
    SetBkMode(dc, TRANSPARENT);
    for (size_t i = 0; i < items_.size(); i++) {
        RECT row = {0, kPad + (int)i * rowHeight_, rc.right, kPad + (int)(i + 1) * rowHeight_};
        bool sel = (int)i == selected_;
        if (sel) FillRect(dc, &row, GetSysColorBrush(COLOR_HIGHLIGHT));
        SetTextColor(dc, GetSysColor(sel ? COLOR_HIGHLIGHTTEXT : COLOR_WINDOWTEXT));
        std::wstring text = numbered_ ? std::to_wstring(i + 1) + L". " + items_[i] : items_[i];
        row.left += kPad;
        DrawTextW(dc, text.c_str(), (int)text.size(), &row, DT_SINGLELINE | DT_VCENTER | DT_NOPREFIX);
    }
    SelectObject(dc, old);
}

int CandidateWindow::HitTest(int y) const {
    if (rowHeight_ <= 0 || !numbered_) return -1;
    int i = (y - kPad) / rowHeight_;
    return y >= kPad && i >= 0 && i < (int)items_.size() ? i : -1;
}

LRESULT CALLBACK CandidateWindow::WndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    auto* self = (CandidateWindow*)GetWindowLongPtrW(hwnd, GWLP_USERDATA);
    switch (msg) {
    case WM_PAINT: {
        PAINTSTRUCT ps;
        HDC dc = BeginPaint(hwnd, &ps);
        if (self) self->Paint(dc);
        EndPaint(hwnd, &ps);
        return 0;
    }
    case WM_MOUSEACTIVATE:
        return MA_NOACTIVATE;
    case WM_LBUTTONDOWN:
        if (self && self->onSelect) {
            int i = self->HitTest(GET_Y_LPARAM(lp));
            if (i >= 0) self->onSelect(i);
        }
        return 0;
    case WM_TIMER:
        if (wp == kFlashTimer) {
            KillTimer(hwnd, kFlashTimer);
            ShowWindow(hwnd, SW_HIDE);
        }
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}
