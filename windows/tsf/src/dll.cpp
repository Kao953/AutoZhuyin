// DLL entry points: COM class factory and registration (regsvr32).
#include "tsf.h"

#include <new>

const CLSID CLSID_AutoZhuyin = {0xa8279f9b, 0x97c4, 0x4113, {0x85, 0x53, 0x09, 0x93, 0xf9, 0x2f, 0xb2, 0xb4}};
const GUID GUID_AutoZhuyinProfile = {0x0e1fba2a, 0x6acd, 0x4a37, {0x99, 0x18, 0xe7, 0x9a, 0xa7, 0x01, 0xbb, 0xae}};
const GUID GUID_AutoZhuyinDisplayAttribute = {0x4fdc6196, 0xec5a, 0x46e7, {0xb8, 0xda, 0x09, 0xd6, 0x20, 0x3e, 0x99, 0x0d}};

HINSTANCE g_hInstance = nullptr;
LONG g_dllRefCount = 0;

// Distinct from the PIME version's name, so both can be installed side by side.
static const wchar_t kName[] = L"自動注音（獨立版）";
static const LANGID kLangId = MAKELANGID(LANG_CHINESE, SUBLANG_CHINESE_TRADITIONAL);   // zh-TW

void DllAddRef() { InterlockedIncrement(&g_dllRefCount); }
void DllRelease() { InterlockedDecrement(&g_dllRefCount); }

std::wstring Utf8ToWide(const std::string& s) {
    if (s.empty()) return L"";
    int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), nullptr, 0);
    std::wstring out(n, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), &out[0], n);
    return out;
}

std::string WideToUtf8(const std::wstring& s) {
    if (s.empty()) return "";
    int n = WideCharToMultiByte(CP_UTF8, 0, s.data(), (int)s.size(), nullptr, 0, nullptr, nullptr);
    std::string out(n, '\0');
    WideCharToMultiByte(CP_UTF8, 0, s.data(), (int)s.size(), &out[0], n, nullptr, nullptr);
    return out;
}

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) {
        g_hInstance = instance;
        DisableThreadLibraryCalls(instance);
        CandidateWindow::RegisterWindowClass();
    } else if (reason == DLL_PROCESS_DETACH) {
        CandidateWindow::UnregisterWindowClass();
    }
    return TRUE;
}

// ---- class factory ----

class ClassFactory : public IClassFactory {
public:
    STDMETHODIMP QueryInterface(REFIID riid, void** ppv) override {
        if (riid == IID_IUnknown || riid == IID_IClassFactory) {
            *ppv = static_cast<IClassFactory*>(this);
            DllAddRef();
            return S_OK;
        }
        *ppv = nullptr;
        return E_NOINTERFACE;
    }
    STDMETHODIMP_(ULONG) AddRef() override { DllAddRef(); return 2; }
    STDMETHODIMP_(ULONG) Release() override { DllRelease(); return 1; }
    STDMETHODIMP CreateInstance(IUnknown* outer, REFIID riid, void** ppv) override {
        *ppv = nullptr;
        if (outer) return CLASS_E_NOAGGREGATION;
        TextService* service = new (std::nothrow) TextService();
        if (!service) return E_OUTOFMEMORY;
        HRESULT hr = service->QueryInterface(riid, ppv);
        service->Release();
        return hr;
    }
    STDMETHODIMP LockServer(BOOL lock) override {
        if (lock) DllAddRef(); else DllRelease();
        return S_OK;
    }
};

static ClassFactory g_factory;

STDAPI DllGetClassObject(REFCLSID clsid, REFIID riid, void** ppv) {
    if (clsid != CLSID_AutoZhuyin) {
        *ppv = nullptr;
        return CLASS_E_CLASSNOTAVAILABLE;
    }
    return g_factory.QueryInterface(riid, ppv);
}

STDAPI DllCanUnloadNow() { return g_dllRefCount <= 0 ? S_OK : S_FALSE; }

// ---- registration ----

static std::wstring ClsidKey() {
    wchar_t clsid[64];
    StringFromGUID2(CLSID_AutoZhuyin, clsid, 64);
    return std::wstring(L"Software\\Classes\\CLSID\\") + clsid;
}

static std::wstring ModulePath() {
    wchar_t path[MAX_PATH];
    GetModuleFileNameW(g_hInstance, path, MAX_PATH);
    return path;
}

static const GUID kCategories[] = {
    GUID_TFCAT_TIP_KEYBOARD,
    GUID_TFCAT_DISPLAYATTRIBUTEPROVIDER,
    GUID_TFCAT_TIPCAP_IMMERSIVESUPPORT,   // Windows 8+ "modern" apps
    GUID_TFCAT_TIPCAP_SYSTRAYSUPPORT,     // listed on the taskbar
};

STDAPI DllRegisterServer() {
    std::wstring key = ClsidKey(), path = ModulePath();
    HKEY k;
    if (RegCreateKeyExW(HKEY_LOCAL_MACHINE, key.c_str(), 0, nullptr, 0, KEY_WRITE, nullptr, &k, nullptr) != ERROR_SUCCESS)
        return SELFREG_E_CLASS;
    RegSetValueExW(k, nullptr, 0, REG_SZ, (const BYTE*)kName, sizeof(kName));
    HKEY inproc;
    if (RegCreateKeyExW(k, L"InprocServer32", 0, nullptr, 0, KEY_WRITE, nullptr, &inproc, nullptr) == ERROR_SUCCESS) {
        RegSetValueExW(inproc, nullptr, 0, REG_SZ, (const BYTE*)path.c_str(), (DWORD)((path.size() + 1) * sizeof(wchar_t)));
        static const wchar_t model[] = L"Apartment";
        RegSetValueExW(inproc, L"ThreadingModel", 0, REG_SZ, (const BYTE*)model, sizeof(model));
        RegCloseKey(inproc);
    }
    RegCloseKey(k);

    HRESULT init = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    HRESULT hr = E_FAIL;
    ITfInputProcessorProfileMgr* profiles = nullptr;
    if (SUCCEEDED(CoCreateInstance(CLSID_TF_InputProcessorProfiles, nullptr, CLSCTX_INPROC_SERVER,
                                   IID_ITfInputProcessorProfileMgr, (void**)&profiles))) {
        hr = profiles->RegisterProfile(CLSID_AutoZhuyin, kLangId, GUID_AutoZhuyinProfile,
                                       kName, (ULONG)wcslen(kName), path.c_str(), (ULONG)path.size(),
                                       0, nullptr, 0, TRUE, 0);
        profiles->Release();
    }
    ITfCategoryMgr* categories = nullptr;
    if (SUCCEEDED(hr) && SUCCEEDED(CoCreateInstance(CLSID_TF_CategoryMgr, nullptr, CLSCTX_INPROC_SERVER,
                                                    IID_ITfCategoryMgr, (void**)&categories))) {
        for (const GUID& cat : kCategories) categories->RegisterCategory(CLSID_AutoZhuyin, cat, CLSID_AutoZhuyin);
        categories->Release();
    }
    if (SUCCEEDED(init)) CoUninitialize();
    return SUCCEEDED(hr) ? S_OK : SELFREG_E_CLASS;
}

STDAPI DllUnregisterServer() {
    HRESULT init = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    ITfInputProcessorProfileMgr* profiles = nullptr;
    if (SUCCEEDED(CoCreateInstance(CLSID_TF_InputProcessorProfiles, nullptr, CLSCTX_INPROC_SERVER,
                                   IID_ITfInputProcessorProfileMgr, (void**)&profiles))) {
        profiles->UnregisterProfile(CLSID_AutoZhuyin, kLangId, GUID_AutoZhuyinProfile, 0);
        profiles->Release();
    }
    ITfCategoryMgr* categories = nullptr;
    if (SUCCEEDED(CoCreateInstance(CLSID_TF_CategoryMgr, nullptr, CLSCTX_INPROC_SERVER,
                                   IID_ITfCategoryMgr, (void**)&categories))) {
        for (const GUID& cat : kCategories) categories->UnregisterCategory(CLSID_AutoZhuyin, cat, CLSID_AutoZhuyin);
        categories->Release();
    }
    if (SUCCEEDED(init)) CoUninitialize();
    RegDeleteTreeW(HKEY_LOCAL_MACHINE, ClsidKey().c_str());
    return S_OK;
}
