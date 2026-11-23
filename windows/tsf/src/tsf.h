// AutoZhuyin stand-alone Windows text service (experimental, no PIME).
//
// The DLL is loaded into every app that takes text input. It only translates keys and
// draws the composition and candidate list; the engine (the shared Python core) runs in
// one per-user server process (../server.py), reached over a named pipe.
#pragma once

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <msctf.h>
#include <olectl.h>

#include "mingw_compat.h"

#include <functional>
#include <string>
#include <vector>

// {A8279F9B-97C4-4113-8553-0993F92FB2B4}
extern const CLSID CLSID_AutoZhuyin;
// {0E1FBA2A-6ACD-4A37-9918-E79AA701BBAE}
extern const GUID GUID_AutoZhuyinProfile;
// {4FDC6196-EC5A-46E7-B8DA-09D6203E990D}
extern const GUID GUID_AutoZhuyinDisplayAttribute;

extern HINSTANCE g_hInstance;
extern LONG g_dllRefCount;

void DllAddRef();
void DllRelease();

std::wstring Utf8ToWide(const std::string& s);
std::string WideToUtf8(const std::wstring& s);

// ---- engine server connection (engine.cpp) ----

struct MenuItem {
    int id = -1;   // -1: a separator
    bool checked = false;
    bool enabled = true;
    std::wstring text;
};

struct EngineReply {
    bool handled = false;
    std::wstring commit;
    std::wstring preedit;
    int cursor = 0;
    std::vector<std::wstring> candidates;   // the current page
    int candidateIndex = 0;
    bool english = false;
    std::wstring text;   // "flippable"
    std::vector<MenuItem> menu;   // "menu"
    std::wstring message;         // "command": what to show briefly
};

class EngineClient {
public:
    ~EngineClient();
    // Sends "op[\targ]". On any failure the reply is "not handled", so keys reach the app.
    EngineReply Request(const std::string& op, const std::string& arg = "");
    void Close();

private:
    bool Connect();
    HANDLE pipe_ = INVALID_HANDLE_VALUE;
    ULONGLONG lastLaunch_ = 0;
};

// ---- candidate window (candidates.cpp) ----

class CandidateWindow {
public:
    // Called with the page index of a clicked candidate.
    std::function<void(int)> onSelect;

    ~CandidateWindow();
    void Show(const std::vector<std::wstring>& items, int selected, const RECT& textRect);
    // A one-item badge ("A" / "中") that hides itself, for English mode on/off.
    void Flash(const std::wstring& text, const RECT& textRect);
    void Hide();
    // The (hidden) popup itself, as an owner for the settings menu.
    HWND Handle();

    static LRESULT CALLBACK WndProc(HWND, UINT, WPARAM, LPARAM);
    static void RegisterWindowClass();
    static void UnregisterWindowClass();

private:
    void Ensure();
    void Layout(const RECT& textRect);
    void Paint(HDC dc);
    int HitTest(int y) const;

    HWND hwnd_ = nullptr;
    HFONT font_ = nullptr;
    std::vector<std::wstring> items_;
    int selected_ = -1;
    bool numbered_ = true;
    int rowHeight_ = 0;
};

// ---- the language bar / taskbar button (langbar.cpp) ----

class TextService;

// 中 / 英 next to the taskbar clock: left click switches English mode, right click opens
// the settings menu (items from the engine server, core/menu.py).
class LangBarButton : public ITfLangBarItemButton, public ITfSource {
public:
    explicit LangBarButton(TextService* service);

    // IUnknown
    STDMETHODIMP QueryInterface(REFIID riid, void** ppv) override;
    STDMETHODIMP_(ULONG) AddRef() override;
    STDMETHODIMP_(ULONG) Release() override;

    // ITfLangBarItem
    STDMETHODIMP GetInfo(TF_LANGBARITEMINFO* info) override;
    STDMETHODIMP GetStatus(DWORD* status) override;
    STDMETHODIMP Show(BOOL show) override;
    STDMETHODIMP GetTooltipString(BSTR* tooltip) override;

    // ITfLangBarItemButton
    STDMETHODIMP OnClick(TfLBIClick click, POINT pt, const RECT* area) override;
    STDMETHODIMP InitMenu(ITfMenu* menu) override;
    STDMETHODIMP OnMenuSelect(UINT id) override;
    STDMETHODIMP GetIcon(HICON* icon) override;
    STDMETHODIMP GetText(BSTR* text) override;

    // ITfSource
    STDMETHODIMP AdviseSink(REFIID riid, IUnknown* sink, DWORD* cookie) override;
    STDMETHODIMP UnadviseSink(DWORD cookie) override;

    // English mode changed: redraw.
    void Update();
    // The service is going away.
    void Detach();

private:
    virtual ~LangBarButton();
    LONG ref_ = 1;
    TextService* service_;
    ITfLangBarItemSink* sink_ = nullptr;
};

// ---- the text service (textservice.cpp) ----

class TextService : public ITfTextInputProcessorEx,
                    public ITfKeyEventSink,
                    public ITfCompositionSink,
                    public ITfDisplayAttributeProvider {
public:
    TextService();

    // IUnknown
    STDMETHODIMP QueryInterface(REFIID riid, void** ppv) override;
    STDMETHODIMP_(ULONG) AddRef() override;
    STDMETHODIMP_(ULONG) Release() override;

    // ITfTextInputProcessor(Ex)
    STDMETHODIMP Activate(ITfThreadMgr* tm, TfClientId id) override;
    STDMETHODIMP ActivateEx(ITfThreadMgr* tm, TfClientId id, DWORD flags) override;
    STDMETHODIMP Deactivate() override;

    // ITfKeyEventSink
    STDMETHODIMP OnSetFocus(BOOL foreground) override;
    STDMETHODIMP OnTestKeyDown(ITfContext* ctx, WPARAM wp, LPARAM lp, BOOL* eaten) override;
    STDMETHODIMP OnKeyDown(ITfContext* ctx, WPARAM wp, LPARAM lp, BOOL* eaten) override;
    STDMETHODIMP OnTestKeyUp(ITfContext* ctx, WPARAM wp, LPARAM lp, BOOL* eaten) override;
    STDMETHODIMP OnKeyUp(ITfContext* ctx, WPARAM wp, LPARAM lp, BOOL* eaten) override;
    STDMETHODIMP OnPreservedKey(ITfContext* ctx, REFGUID guid, BOOL* eaten) override;

    // ITfCompositionSink
    STDMETHODIMP OnCompositionTerminated(TfEditCookie ec, ITfComposition* composition) override;

    // ITfDisplayAttributeProvider
    STDMETHODIMP EnumDisplayAttributeInfo(IEnumTfDisplayAttributeInfo** ppEnum) override;
    STDMETHODIMP GetDisplayAttributeInfo(REFGUID guid, ITfDisplayAttributeInfo** ppInfo) override;

    // From the language bar button.
    bool IsEnglish() const { return english_; }
    void ToggleEnglish();
    void ShowMenu(POINT pt);

private:
    virtual ~TextService();

    // What the engine calls a key ("a", "BS", …), or "" for keys it doesn't take.
    std::string KeyName(WPARAM vk) const;
    bool ControlChar(WPARAM vk, std::string* c) const;
    bool ShortcutModifiers() const;
    // Runs `fn` in a read/write edit session on `ctx` (synchronous unless `async`).
    // Returns false if the session wasn't granted.
    bool Edit(ITfContext* ctx, const std::function<void(TfEditCookie)>& fn, bool async = false,
              bool readOnly = false);
    // The selection, if it is a caret right after `text`, widened to cover `text`.
    ITfRange* RangeBeforeCaret(TfEditCookie ec, ITfContext* ctx, const std::wstring& text);
    // Tab right after a commit: whether the committed text is still before the caret.
    bool CanFlip(ITfContext* ctx);
    void Flip(ITfContext* ctx);
    // Puts the engine's reply on screen: committed text, composition, candidates.
    void Apply(ITfContext* ctx, const EngineReply& reply, bool async = false);
    void ApplyInSession(TfEditCookie ec, ITfContext* ctx, const EngineReply& reply);
    void SetComposition(TfEditCookie ec, ITfContext* ctx, const std::wstring& text, int cursor);
    void EndComposition(TfEditCookie ec);
    RECT TextRect(TfEditCookie ec, ITfContext* ctx);
    void ShiftTap(ITfContext* ctx);
    // The context with focus in this thread (for the button, which has no key event).
    ITfContext* FocusedContext();
    // Shows `text` briefly by the caret (English mode, menu results).
    void Flash(ITfContext* ctx, const std::wstring& text);
    void SetEnglish(bool english);

    LONG ref_ = 1;
    ITfThreadMgr* threadMgr_ = nullptr;
    TfClientId clientId_ = TF_CLIENTID_NULL;
    ITfComposition* composition_ = nullptr;
    ITfContext* compositionContext_ = nullptr;
    TfGuidAtom displayAtom_ = TF_INVALID_GUIDATOM;
    EngineClient engine_;
    CandidateWindow candidates_;
    LangBarButton* button_ = nullptr;
    bool english_ = false;
    std::wstring flipText_;   // the commit Tab would replace (set by CanFlip)

    // Shift pressed and released alone (port of ShiftTapDetector).
    ULONGLONG shiftDownAt_ = 0;
    bool shiftUsed_ = false;
};

// Display attribute for the composition: a dotted underline, the app's own colors.
class DisplayAttributeInfo : public ITfDisplayAttributeInfo {
public:
    STDMETHODIMP QueryInterface(REFIID riid, void** ppv) override;
    STDMETHODIMP_(ULONG) AddRef() override;
    STDMETHODIMP_(ULONG) Release() override;
    STDMETHODIMP GetGUID(GUID* guid) override;
    STDMETHODIMP GetDescription(BSTR* desc) override;
    STDMETHODIMP GetAttributeInfo(TF_DISPLAYATTRIBUTE* attr) override;
    STDMETHODIMP SetAttributeInfo(const TF_DISPLAYATTRIBUTE*) override;
    STDMETHODIMP Reset() override;
    DisplayAttributeInfo() { DllAddRef(); }
    virtual ~DisplayAttributeInfo() { DllRelease(); }

private:
    LONG ref_ = 1;
};

class DisplayAttributeEnum : public IEnumTfDisplayAttributeInfo {
public:
    STDMETHODIMP QueryInterface(REFIID riid, void** ppv) override;
    STDMETHODIMP_(ULONG) AddRef() override;
    STDMETHODIMP_(ULONG) Release() override;
    STDMETHODIMP Clone(IEnumTfDisplayAttributeInfo** ppEnum) override;
    STDMETHODIMP Next(ULONG count, ITfDisplayAttributeInfo** info, ULONG* fetched) override;
    STDMETHODIMP Reset() override;
    STDMETHODIMP Skip(ULONG count) override;
    DisplayAttributeEnum() { DllAddRef(); }
    virtual ~DisplayAttributeEnum() { DllRelease(); }

private:
    LONG ref_ = 1;
    ULONG index_ = 0;
};
