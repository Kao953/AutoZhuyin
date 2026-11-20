// The TSF text service: keys → engine server → composition / commit / candidates.
#include "tsf.h"

// ---- edit sessions ----

class EditSession : public ITfEditSession {
public:
    explicit EditSession(std::function<void(TfEditCookie)> fn) : fn_(std::move(fn)) {}
    STDMETHODIMP QueryInterface(REFIID riid, void** ppv) override {
        if (riid == IID_IUnknown || riid == IID_ITfEditSession) {
            *ppv = static_cast<ITfEditSession*>(this);
            AddRef();
            return S_OK;
        }
        *ppv = nullptr;
        return E_NOINTERFACE;
    }
    STDMETHODIMP_(ULONG) AddRef() override { return InterlockedIncrement(&ref_); }
    STDMETHODIMP_(ULONG) Release() override {
        LONG r = InterlockedDecrement(&ref_);
        if (r == 0) delete this;
        return r;
    }
    STDMETHODIMP DoEditSession(TfEditCookie ec) override {
        fn_(ec);
        return S_OK;
    }

private:
    virtual ~EditSession() = default;
    std::function<void(TfEditCookie)> fn_;
    LONG ref_ = 1;
};

// ---- lifetime ----

TextService::TextService() {
    DllAddRef();
    candidates_.onSelect = [this](int index) {
        if (!compositionContext_) return;
        EngineReply reply = engine_.Request("select", std::to_string(index));
        ITfContext* ctx = compositionContext_;
        ctx->AddRef();
        Edit(ctx, [this, ctx, reply](TfEditCookie ec) { ApplyInSession(ec, ctx, reply); }, true);
        ctx->Release();
    };
}

TextService::~TextService() { DllRelease(); }

STDMETHODIMP TextService::QueryInterface(REFIID riid, void** ppv) {
    if (!ppv) return E_INVALIDARG;
    if (riid == IID_IUnknown || riid == IID_ITfTextInputProcessor || riid == IID_ITfTextInputProcessorEx)
        *ppv = static_cast<ITfTextInputProcessorEx*>(this);
    else if (riid == IID_ITfKeyEventSink)
        *ppv = static_cast<ITfKeyEventSink*>(this);
    else if (riid == IID_ITfCompositionSink)
        *ppv = static_cast<ITfCompositionSink*>(this);
    else if (riid == IID_ITfDisplayAttributeProvider)
        *ppv = static_cast<ITfDisplayAttributeProvider*>(this);
    else {
        *ppv = nullptr;
        return E_NOINTERFACE;
    }
    AddRef();
    return S_OK;
}

STDMETHODIMP_(ULONG) TextService::AddRef() { return InterlockedIncrement(&ref_); }

STDMETHODIMP_(ULONG) TextService::Release() {
    LONG r = InterlockedDecrement(&ref_);
    if (r == 0) delete this;
    return r;
}

STDMETHODIMP TextService::Activate(ITfThreadMgr* tm, TfClientId id) { return ActivateEx(tm, id, 0); }

STDMETHODIMP TextService::ActivateEx(ITfThreadMgr* tm, TfClientId id, DWORD) {
    threadMgr_ = tm;
    threadMgr_->AddRef();
    clientId_ = id;
    ITfKeystrokeMgr* keys = nullptr;
    if (SUCCEEDED(tm->QueryInterface(IID_ITfKeystrokeMgr, (void**)&keys))) {
        keys->AdviseKeyEventSink(id, static_cast<ITfKeyEventSink*>(this), TRUE);
        keys->Release();
    }
    ITfCategoryMgr* categories = nullptr;
    if (SUCCEEDED(CoCreateInstance(CLSID_TF_CategoryMgr, nullptr, CLSCTX_INPROC_SERVER, IID_ITfCategoryMgr,
                                   (void**)&categories))) {
        categories->RegisterGUID(GUID_AutoZhuyinDisplayAttribute, &displayAtom_);
        categories->Release();
    }
    return S_OK;
}

STDMETHODIMP TextService::Deactivate() {
    candidates_.Hide();
    if (composition_) {
        // The composition is left as plain text; the engine forgets it.
        composition_->Release();
        composition_ = nullptr;
    }
    if (compositionContext_) {
        compositionContext_->Release();
        compositionContext_ = nullptr;
    }
    engine_.Request("reset");
    engine_.Close();
    if (threadMgr_) {
        ITfKeystrokeMgr* keys = nullptr;
        if (SUCCEEDED(threadMgr_->QueryInterface(IID_ITfKeystrokeMgr, (void**)&keys))) {
            keys->UnadviseKeyEventSink(clientId_);
            keys->Release();
        }
        threadMgr_->Release();
        threadMgr_ = nullptr;
    }
    clientId_ = TF_CLIENTID_NULL;
    return S_OK;
}

// ---- keys ----

static bool Down(int vk) { return (GetKeyState(vk) & 0x8000) != 0; }

bool TextService::ShortcutModifiers() const { return Down(VK_CONTROL) || Down(VK_MENU) || Down(VK_LWIN) || Down(VK_RWIN); }

std::string TextService::KeyName(WPARAM vk) const {
    switch (vk) {
    case VK_BACK: return "BS";
    case VK_RETURN: return "ENTER";
    case VK_ESCAPE: return "ESC";
    case VK_TAB: return "TAB";
    case VK_UP: return "UP";
    case VK_DOWN: return "DOWN";
    case VK_LEFT: return "LEFT";
    case VK_RIGHT: return "RIGHT";
    case VK_SPACE: return " ";
    }
    // The character the key types with the current Shift state. Caps Lock is ignored, so
    // Zhuyin keeps working with it on (Shift still gives capitals).
    BYTE state[256];
    if (!GetKeyboardState(state)) return "";
    state[VK_CAPITAL] = 0;
    state[VK_CONTROL] = state[VK_LCONTROL] = state[VK_RCONTROL] = 0;
    state[VK_MENU] = state[VK_LMENU] = state[VK_RMENU] = 0;
    wchar_t buf[4];
    int n = ToUnicodeEx((UINT)vk, MapVirtualKeyW((UINT)vk, MAPVK_VK_TO_VSC), state, buf, 4, 0x4, GetKeyboardLayout(0));
    if (n != 1 || buf[0] < 0x20 || buf[0] == 0x7f) return "";
    return WideToUtf8(std::wstring(1, buf[0]));
}

// Ctrl + ; ' , . / → full-width ；、，。？ (engine "ctrl").
bool TextService::ControlChar(WPARAM vk, std::string* c) const {
    if (!Down(VK_CONTROL) || Down(VK_MENU)) return false;
    switch (vk) {
    case VK_OEM_1: *c = ";"; return true;
    case VK_OEM_7: *c = "'"; return true;
    case VK_OEM_COMMA: *c = ","; return true;
    case VK_OEM_PERIOD: *c = "."; return true;
    case VK_OEM_2: *c = "/"; return true;
    }
    return false;
}

STDMETHODIMP TextService::OnSetFocus(BOOL foreground) {
    if (!foreground) candidates_.Hide();
    return S_OK;
}

STDMETHODIMP TextService::OnTestKeyDown(ITfContext* ctx, WPARAM vk, LPARAM, BOOL* eaten) {
    *eaten = FALSE;
    if (vk == VK_SHIFT) {
        if (shiftDownAt_ == 0) {   // ignore auto-repeat
            shiftDownAt_ = GetTickCount64();
            shiftUsed_ = ShortcutModifiers();
        }
        return S_OK;
    }
    if (shiftDownAt_) shiftUsed_ = true;
    std::string c;
    if (ControlChar(vk, &c)) {
        *eaten = engine_.Request("testctrl", c).handled;
        return S_OK;
    }
    if (ShortcutModifiers()) {
        // Shortcuts go to the app; commit the composition first (like ⌘C on the Mac). A test
        // handler can't edit the document synchronously.
        if (composition_) Apply(ctx, engine_.Request("commit"), true);
        return S_OK;
    }
    std::string key = KeyName(vk);
    if (key.empty()) {
        *eaten = composition_ != nullptr;   // swallow Delete, Home… while composing
        return S_OK;
    }
    *eaten = engine_.Request("test", key).handled;
    return S_OK;
}

STDMETHODIMP TextService::OnKeyDown(ITfContext* ctx, WPARAM vk, LPARAM lp, BOOL* eaten) {
    OnTestKeyDown(ctx, vk, lp, eaten);
    if (!*eaten || vk == VK_SHIFT) return S_OK;
    std::string c;
    if (ControlChar(vk, &c)) {
        Apply(ctx, engine_.Request("ctrl", c));
        return S_OK;
    }
    std::string key = KeyName(vk);
    if (key.empty()) return S_OK;
    EngineReply reply = engine_.Request("key", key);
    *eaten = reply.handled;
    Apply(ctx, reply);
    return S_OK;
}

// Shift released alone: English mode on/off, or flip the word being typed. The key-up
// itself always goes to the app, so it never thinks Shift is still down.
STDMETHODIMP TextService::OnTestKeyUp(ITfContext* ctx, WPARAM vk, LPARAM, BOOL* eaten) {
    *eaten = FALSE;
    if (vk != VK_SHIFT || shiftDownAt_ == 0) return S_OK;
    bool tap = !shiftUsed_ && GetTickCount64() - shiftDownAt_ <= 500;
    shiftDownAt_ = 0;
    if (tap) ShiftTap(ctx);
    return S_OK;
}

STDMETHODIMP TextService::OnKeyUp(ITfContext* ctx, WPARAM vk, LPARAM lp, BOOL* eaten) {
    return OnTestKeyUp(ctx, vk, lp, eaten);
}

void TextService::ShiftTap(ITfContext* ctx) {
    bool idle = composition_ == nullptr;
    EngineReply reply = engine_.Request("shift");
    Apply(ctx, reply, true);   // called from a key-up test handler: no synchronous edits
    if (idle && ctx) {
        bool english = reply.english;
        Edit(ctx, [this, ctx, english](TfEditCookie ec) {
            candidates_.Flash(english ? L"A" : L"中", TextRect(ec, ctx));
        }, true);
    }
}

STDMETHODIMP TextService::OnPreservedKey(ITfContext*, REFGUID, BOOL* eaten) {
    *eaten = FALSE;
    return S_OK;
}

// ---- putting text in the app ----

void TextService::Edit(ITfContext* ctx, const std::function<void(TfEditCookie)>& fn, bool async) {
    if (!ctx) return;
    EditSession* session = new EditSession(fn);
    HRESULT hr;
    ctx->RequestEditSession(clientId_, session, (async ? TF_ES_ASYNCDONTCARE : TF_ES_SYNC) | TF_ES_READWRITE, &hr);
    session->Release();
}

void TextService::Apply(ITfContext* ctx, const EngineReply& reply, bool async) {
    if (!ctx) return;
    english_ = reply.english;
    bool needed = !reply.commit.empty() || !reply.preedit.empty() || composition_ || !reply.candidates.empty();
    if (needed) Edit(ctx, [this, ctx, reply](TfEditCookie ec) { ApplyInSession(ec, ctx, reply); }, async);
    if (reply.candidates.empty()) candidates_.Hide();
}

// Python counts code points; TSF counts UTF-16 units.
static LONG Utf16Offset(const std::wstring& s, int codePoints) {
    LONG i = 0;
    for (int n = 0; n < codePoints && i < (LONG)s.size(); n++) i += IS_HIGH_SURROGATE(s[i]) ? 2 : 1;
    return i < (LONG)s.size() ? i : (LONG)s.size();
}

void TextService::ApplyInSession(TfEditCookie ec, ITfContext* ctx, const EngineReply& reply) {
    if (!reply.commit.empty()) {
        if (composition_) {
            // Replace the composition with the committed text and end it.
            ITfRange* range = nullptr;
            if (SUCCEEDED(composition_->GetRange(&range))) {
                range->SetText(ec, 0, reply.commit.c_str(), (LONG)reply.commit.size());
                range->Collapse(ec, TF_ANCHOR_END);
                TF_SELECTION sel = {range, {TF_AE_NONE, FALSE}};
                ctx->SetSelection(ec, 1, &sel);
                range->Release();
            }
            EndComposition(ec);
        } else {
            ITfInsertAtSelection* insert = nullptr;
            if (SUCCEEDED(ctx->QueryInterface(IID_ITfInsertAtSelection, (void**)&insert))) {
                ITfRange* range = nullptr;
                if (SUCCEEDED(insert->InsertTextAtSelection(ec, 0, reply.commit.c_str(), (LONG)reply.commit.size(),
                                                            &range)) && range) {
                    range->Collapse(ec, TF_ANCHOR_END);
                    TF_SELECTION sel = {range, {TF_AE_NONE, FALSE}};
                    ctx->SetSelection(ec, 1, &sel);
                    range->Release();
                }
                insert->Release();
            }
        }
    }
    if (!reply.preedit.empty()) {
        SetComposition(ec, ctx, reply.preedit, (int)Utf16Offset(reply.preedit, reply.cursor));
    } else if (composition_) {
        ITfRange* range = nullptr;
        if (SUCCEEDED(composition_->GetRange(&range))) {
            range->SetText(ec, 0, L"", 0);
            range->Release();
        }
        EndComposition(ec);
    }
    if (!reply.candidates.empty()) candidates_.Show(reply.candidates, reply.candidateIndex, TextRect(ec, ctx));
}

void TextService::SetComposition(TfEditCookie ec, ITfContext* ctx, const std::wstring& text, int cursor) {
    if (!composition_) {
        ITfInsertAtSelection* insert = nullptr;
        ITfContextComposition* cc = nullptr;
        ITfRange* range = nullptr;
        if (SUCCEEDED(ctx->QueryInterface(IID_ITfInsertAtSelection, (void**)&insert)) &&
            SUCCEEDED(insert->InsertTextAtSelection(ec, TF_IAS_QUERYONLY, nullptr, 0, &range)) && range &&
            SUCCEEDED(ctx->QueryInterface(IID_ITfContextComposition, (void**)&cc))) {
            cc->StartComposition(ec, range, static_cast<ITfCompositionSink*>(this), &composition_);
        }
        if (range) range->Release();
        if (cc) cc->Release();
        if (insert) insert->Release();
        if (!composition_) return;
        compositionContext_ = ctx;
        compositionContext_->AddRef();
    }
    ITfRange* range = nullptr;
    if (FAILED(composition_->GetRange(&range))) return;
    range->SetText(ec, TF_ST_CORRECTION, text.c_str(), (LONG)text.size());

    // Underline the composition (display attribute).
    ITfProperty* prop = nullptr;
    if (displayAtom_ != TF_INVALID_GUIDATOM && SUCCEEDED(ctx->GetProperty(GUID_PROP_ATTRIBUTE, &prop))) {
        VARIANT v;
        v.vt = VT_I4;
        v.lVal = (LONG)displayAtom_;
        prop->SetValue(ec, range, &v);
        prop->Release();
    }

    // Caret at the engine's cursor.
    ITfRange* caret = nullptr;
    if (SUCCEEDED(range->Clone(&caret))) {
        LONG moved;
        caret->Collapse(ec, TF_ANCHOR_START);
        caret->ShiftEnd(ec, cursor, &moved, nullptr);
        caret->Collapse(ec, TF_ANCHOR_END);
        TF_SELECTION sel = {caret, {TF_AE_NONE, FALSE}};
        ctx->SetSelection(ec, 1, &sel);
        caret->Release();
    }
    range->Release();
}

void TextService::EndComposition(TfEditCookie ec) {
    if (composition_) {
        ITfRange* range = nullptr;
        if (SUCCEEDED(composition_->GetRange(&range))) {
            ITfProperty* prop = nullptr;
            if (compositionContext_ && SUCCEEDED(compositionContext_->GetProperty(GUID_PROP_ATTRIBUTE, &prop))) {
                prop->Clear(ec, range);
                prop->Release();
            }
            range->Release();
        }
        composition_->EndComposition(ec);
        composition_->Release();
        composition_ = nullptr;
    }
    if (compositionContext_) {
        compositionContext_->Release();
        compositionContext_ = nullptr;
    }
    candidates_.Hide();
}

STDMETHODIMP TextService::OnCompositionTerminated(TfEditCookie, ITfComposition*) {
    // The app ended the composition (focus change, mouse click): the shown text stays.
    if (composition_) {
        composition_->Release();
        composition_ = nullptr;
    }
    if (compositionContext_) {
        compositionContext_->Release();
        compositionContext_ = nullptr;
    }
    engine_.Request("reset");
    candidates_.Hide();
    return S_OK;
}

// Screen rectangle of the composition (or the caret), for placing the candidate list.
RECT TextService::TextRect(TfEditCookie ec, ITfContext* ctx) {
    RECT rc = {0, 0, 0, 0};
    ITfRange* range = nullptr;
    if (composition_) {
        composition_->GetRange(&range);
    } else {
        TF_SELECTION sel;
        ULONG n = 0;
        if (SUCCEEDED(ctx->GetSelection(ec, TF_DEFAULT_SELECTION, 1, &sel, &n)) && n == 1) range = sel.range;
    }
    ITfContextView* view = nullptr;
    if (range && SUCCEEDED(ctx->GetActiveView(&view))) {
        BOOL clipped;
        view->GetTextExt(ec, range, &rc, &clipped);
        view->Release();
    }
    if (range) range->Release();
    if (rc.left == 0 && rc.top == 0 && rc.bottom == 0) {   // no position from the app: the caret
        GUITHREADINFO gti = {sizeof(gti)};
        if (GetGUIThreadInfo(0, &gti) && gti.hwndCaret) {
            rc = gti.rcCaret;
            MapWindowPoints(gti.hwndCaret, nullptr, (POINT*)&rc, 2);
        }
    }
    return rc;
}

// ---- display attribute provider ----

STDMETHODIMP TextService::EnumDisplayAttributeInfo(IEnumTfDisplayAttributeInfo** ppEnum) {
    *ppEnum = new DisplayAttributeEnum();
    return S_OK;
}

STDMETHODIMP TextService::GetDisplayAttributeInfo(REFGUID guid, ITfDisplayAttributeInfo** ppInfo) {
    if (guid != GUID_AutoZhuyinDisplayAttribute) {
        *ppInfo = nullptr;
        return E_INVALIDARG;
    }
    *ppInfo = new DisplayAttributeInfo();
    return S_OK;
}

STDMETHODIMP DisplayAttributeInfo::QueryInterface(REFIID riid, void** ppv) {
    if (riid == IID_IUnknown || riid == IID_ITfDisplayAttributeInfo) {
        *ppv = static_cast<ITfDisplayAttributeInfo*>(this);
        AddRef();
        return S_OK;
    }
    *ppv = nullptr;
    return E_NOINTERFACE;
}
STDMETHODIMP_(ULONG) DisplayAttributeInfo::AddRef() { return InterlockedIncrement(&ref_); }
STDMETHODIMP_(ULONG) DisplayAttributeInfo::Release() {
    LONG r = InterlockedDecrement(&ref_);
    if (r == 0) delete this;
    return r;
}
STDMETHODIMP DisplayAttributeInfo::GetGUID(GUID* guid) {
    *guid = GUID_AutoZhuyinDisplayAttribute;
    return S_OK;
}
STDMETHODIMP DisplayAttributeInfo::GetDescription(BSTR* desc) {
    *desc = SysAllocString(L"AutoZhuyin composition");
    return *desc ? S_OK : E_OUTOFMEMORY;
}
STDMETHODIMP DisplayAttributeInfo::GetAttributeInfo(TF_DISPLAYATTRIBUTE* attr) {
    attr->crText.type = TF_CT_NONE;
    attr->crBk.type = TF_CT_NONE;
    attr->lsStyle = TF_LS_DOT;
    attr->fBoldLine = FALSE;
    attr->crLine.type = TF_CT_NONE;
    attr->bAttr = TF_ATTR_INPUT;
    return S_OK;
}
STDMETHODIMP DisplayAttributeInfo::SetAttributeInfo(const TF_DISPLAYATTRIBUTE*) { return E_NOTIMPL; }
STDMETHODIMP DisplayAttributeInfo::Reset() { return S_OK; }

STDMETHODIMP DisplayAttributeEnum::QueryInterface(REFIID riid, void** ppv) {
    if (riid == IID_IUnknown || riid == IID_IEnumTfDisplayAttributeInfo) {
        *ppv = static_cast<IEnumTfDisplayAttributeInfo*>(this);
        AddRef();
        return S_OK;
    }
    *ppv = nullptr;
    return E_NOINTERFACE;
}
STDMETHODIMP_(ULONG) DisplayAttributeEnum::AddRef() { return InterlockedIncrement(&ref_); }
STDMETHODIMP_(ULONG) DisplayAttributeEnum::Release() {
    LONG r = InterlockedDecrement(&ref_);
    if (r == 0) delete this;
    return r;
}
STDMETHODIMP DisplayAttributeEnum::Clone(IEnumTfDisplayAttributeInfo** ppEnum) {
    auto* e = new DisplayAttributeEnum();
    e->index_ = index_;
    *ppEnum = e;
    return S_OK;
}
STDMETHODIMP DisplayAttributeEnum::Next(ULONG count, ITfDisplayAttributeInfo** info, ULONG* fetched) {
    ULONG n = 0;
    if (count > 0 && index_ == 0) {
        info[0] = new DisplayAttributeInfo();
        index_ = 1;
        n = 1;
    }
    if (fetched) *fetched = n;
    return n == count ? S_OK : S_FALSE;
}
STDMETHODIMP DisplayAttributeEnum::Reset() {
    index_ = 0;
    return S_OK;
}
STDMETHODIMP DisplayAttributeEnum::Skip(ULONG count) {
    index_ += count;
    return index_ <= 1 ? S_OK : S_FALSE;
}
