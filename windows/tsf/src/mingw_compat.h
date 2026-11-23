// TSF declarations missing from the mingw-w64 headers (the Windows SDK has them).
#pragma once

#ifdef __MINGW32__
#define TF_CLIENTID_NULL 0
#define TF_INVALID_GUIDATOM 0

static const GUID GUID_TFCAT_TIPCAP_IMMERSIVESUPPORT =
    {0x13a016df, 0x560b, 0x46cd, {0x94, 0x7a, 0x4c, 0x3a, 0xf1, 0xe0, 0xe3, 0x5d}};
static const GUID GUID_TFCAT_TIPCAP_SYSTRAYSUPPORT =
    {0x25504fb4, 0x7bab, 0x4bc1, {0x9c, 0x69, 0xcf, 0x81, 0x89, 0x0f, 0x0e, 0xf5}};
static const IID IID_ITfTextInputProcessorEx =
    {0x6e4e2102, 0xf9cd, 0x433d, {0xb4, 0x96, 0x30, 0x3c, 0xe0, 0x3a, 0x65, 0x07}};
static const IID IID_ITfDisplayAttributeProvider =
    {0xfee47777, 0x163c, 0x4769, {0x99, 0x6a, 0x6e, 0x9c, 0x50, 0xad, 0x8f, 0x54}};

struct ITfTextInputProcessorEx : public ITfTextInputProcessor {
    virtual HRESULT STDMETHODCALLTYPE ActivateEx(ITfThreadMgr* ptim, TfClientId tid, DWORD dwFlags) = 0;
};

// Language bar / taskbar input indicator button (ctfutb.h in the Windows SDK).
typedef enum { TF_LBI_CLK_RIGHT = 1, TF_LBI_CLK_LEFT = 2 } TfLBIClick;
#define TF_LBI_STYLE_SHOWNINTRAY 0x00000002
#define TF_LBI_STYLE_BTN_BUTTON 0x00010000
#define TF_LBI_ICON 0x00000001
#define TF_LBI_TEXT 0x00000002
#define TF_LBI_TOOLTIP 0x00000004

// The input mode item: on Windows 8+ it is the 中/英 icon next to the taskbar clock.
static const GUID GUID_LBI_INPUTMODE =
    {0x2c77a81e, 0x41cc, 0x4178, {0xa3, 0xa7, 0x5f, 0x8a, 0x98, 0x75, 0x68, 0xe6}};
static const IID IID_ITfLangBarItemButton =
    {0x28c7f1d0, 0xde25, 0x11d2, {0xaf, 0xdd, 0x00, 0x10, 0x5a, 0x27, 0x99, 0xb5}};

struct ITfMenu;

struct ITfLangBarItemButton : public ITfLangBarItem {
    virtual HRESULT STDMETHODCALLTYPE OnClick(TfLBIClick click, POINT pt, const RECT* prcArea) = 0;
    virtual HRESULT STDMETHODCALLTYPE InitMenu(ITfMenu* pMenu) = 0;
    virtual HRESULT STDMETHODCALLTYPE OnMenuSelect(UINT wID) = 0;
    virtual HRESULT STDMETHODCALLTYPE GetIcon(HICON* phIcon) = 0;
    virtual HRESULT STDMETHODCALLTYPE GetText(BSTR* pbstrText) = 0;
};

struct ITfDisplayAttributeProvider : public IUnknown {
    virtual HRESULT STDMETHODCALLTYPE EnumDisplayAttributeInfo(IEnumTfDisplayAttributeInfo** ppEnum) = 0;
    virtual HRESULT STDMETHODCALLTYPE GetDisplayAttributeInfo(REFGUID guid, ITfDisplayAttributeInfo** ppInfo) = 0;
};
#endif
