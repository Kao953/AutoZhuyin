// The language bar / taskbar input indicator button (GUID_LBI_INPUTMODE): 中 or 英.
#include "tsf.h"

LangBarButton::LangBarButton(TextService* service) : service_(service) { DllAddRef(); }

LangBarButton::~LangBarButton() {
    if (sink_) sink_->Release();
    DllRelease();
}

void LangBarButton::Detach() { service_ = nullptr; }

STDMETHODIMP LangBarButton::QueryInterface(REFIID riid, void** ppv) {
    if (!ppv) return E_INVALIDARG;
    if (riid == IID_IUnknown || riid == IID_ITfLangBarItem || riid == IID_ITfLangBarItemButton)
        *ppv = static_cast<ITfLangBarItemButton*>(this);
    else if (riid == IID_ITfSource)
        *ppv = static_cast<ITfSource*>(this);
    else {
        *ppv = nullptr;
        return E_NOINTERFACE;
    }
    AddRef();
    return S_OK;
}

STDMETHODIMP_(ULONG) LangBarButton::AddRef() { return InterlockedIncrement(&ref_); }

STDMETHODIMP_(ULONG) LangBarButton::Release() {
    LONG r = InterlockedDecrement(&ref_);
    if (r == 0) delete this;
    return r;
}

STDMETHODIMP LangBarButton::GetInfo(TF_LANGBARITEMINFO* info) {
    info->clsidService = CLSID_AutoZhuyin;
    info->guidItem = GUID_LBI_INPUTMODE;
    info->dwStyle = TF_LBI_STYLE_BTN_BUTTON | TF_LBI_STYLE_SHOWNINTRAY;
    info->ulSort = 0;
    lstrcpynW(info->szDescription, L"自動注音", TF_LBI_DESC_MAXLEN);
    return S_OK;
}

STDMETHODIMP LangBarButton::GetStatus(DWORD* status) {
    *status = 0;
    return S_OK;
}

STDMETHODIMP LangBarButton::Show(BOOL) { return S_OK; }

STDMETHODIMP LangBarButton::GetTooltipString(BSTR* tooltip) {
    bool english = service_ && service_->IsEnglish();
    *tooltip = SysAllocString(english ? L"英文模式（按一下或單按 Shift 切回中英自動；右鍵：設定）"
                                      : L"中英自動（按一下或單按 Shift 切換英文模式；右鍵：設定）");
    return *tooltip ? S_OK : E_OUTOFMEMORY;
}

STDMETHODIMP LangBarButton::OnClick(TfLBIClick click, POINT pt, const RECT*) {
    if (!service_) return S_OK;
    if (click == TF_LBI_CLK_LEFT) service_->ToggleEnglish();
    else service_->ShowMenu(pt);
    return S_OK;
}

STDMETHODIMP LangBarButton::InitMenu(ITfMenu*) { return E_NOTIMPL; }   // a button: OnClick shows the menu

STDMETHODIMP LangBarButton::OnMenuSelect(UINT) { return E_NOTIMPL; }

STDMETHODIMP LangBarButton::GetIcon(HICON* icon) {
    // Icon 1: 中 (the input method's icon), icon 2: A. The caller destroys it.
    bool english = service_ && service_->IsEnglish();
    int size = GetSystemMetrics(SM_CXSMICON);
    *icon = (HICON)LoadImageW(g_hInstance, MAKEINTRESOURCEW(english ? 2 : 1), IMAGE_ICON, size, size, 0);
    return *icon ? S_OK : E_FAIL;
}

STDMETHODIMP LangBarButton::GetText(BSTR* text) {
    bool english = service_ && service_->IsEnglish();
    *text = SysAllocString(english ? L"英" : L"中");
    return *text ? S_OK : E_OUTOFMEMORY;
}

STDMETHODIMP LangBarButton::AdviseSink(REFIID riid, IUnknown* sink, DWORD* cookie) {
    if (riid != IID_ITfLangBarItemSink) return CONNECT_E_CANNOTCONNECT;
    if (sink_) return CONNECT_E_ADVISELIMIT;
    if (FAILED(sink->QueryInterface(IID_ITfLangBarItemSink, (void**)&sink_))) {
        sink_ = nullptr;
        return E_NOINTERFACE;
    }
    *cookie = 1;
    return S_OK;
}

STDMETHODIMP LangBarButton::UnadviseSink(DWORD cookie) {
    if (cookie != 1 || !sink_) return CONNECT_E_NOCONNECTION;
    sink_->Release();
    sink_ = nullptr;
    return S_OK;
}

void LangBarButton::Update() {
    if (sink_) sink_->OnUpdate(TF_LBI_ICON | TF_LBI_TEXT | TF_LBI_TOOLTIP);
}
