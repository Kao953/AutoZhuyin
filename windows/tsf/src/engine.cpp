// Named-pipe connection to the per-user engine server (../server.py).
//
// Install layout: <dir>\x64\AutoZhuyinTSF.dll, <dir>\x86\AutoZhuyinTSF.dll,
// <dir>\python\pythonw.exe, <dir>\server.py. The server normally starts at sign-in; if
// the pipe isn't there, the DLL starts it (at most every few seconds) and waits a moment.
#include "tsf.h"

static std::wstring PipeName() {
    wchar_t user[256];
    DWORD n = 256;
    if (!GetUserNameW(user, &n)) wcscpy(user, L"user");
    return std::wstring(L"\\\\.\\pipe\\AutoZhuyin-") + user;
}

static std::wstring InstallDir() {
    wchar_t path[MAX_PATH];
    GetModuleFileNameW(g_hInstance, path, MAX_PATH);
    std::wstring p = path;
    for (int i = 0; i < 2; i++) {   // ...\x64\AutoZhuyinTSF.dll → ...
        size_t slash = p.find_last_of(L'\\');
        if (slash != std::wstring::npos) p.resize(slash);
    }
    return p;
}

static void LaunchServer() {
    std::wstring dir = InstallDir();
    std::wstring cmd = L"\"" + dir + L"\\python\\pythonw.exe\" \"" + dir + L"\\server.py\"";
    STARTUPINFOW si = {};
    si.cb = sizeof(si);
    PROCESS_INFORMATION pi;
    if (CreateProcessW(nullptr, &cmd[0], nullptr, nullptr, FALSE, CREATE_NO_WINDOW | DETACHED_PROCESS,
                       nullptr, dir.c_str(), &si, &pi)) {
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
    }
}

EngineClient::~EngineClient() { Close(); }

void EngineClient::Close() {
    if (pipe_ != INVALID_HANDLE_VALUE) CloseHandle(pipe_);
    pipe_ = INVALID_HANDLE_VALUE;
}

bool EngineClient::Connect() {
    if (pipe_ != INVALID_HANDLE_VALUE) return true;
    std::wstring name = PipeName();
    for (int attempt = 0; attempt < 30; attempt++) {
        pipe_ = CreateFileW(name.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr, OPEN_EXISTING, 0, nullptr);
        if (pipe_ != INVALID_HANDLE_VALUE) break;
        DWORD err = GetLastError();
        if (err == ERROR_PIPE_BUSY) {
            WaitNamedPipeW(name.c_str(), 200);
            continue;
        }
        if (err != ERROR_FILE_NOT_FOUND) return false;
        // No server: start one, then give it up to ~3 s to load the lexicon.
        ULONGLONG now = GetTickCount64();
        if (attempt == 0) {
            if (now - lastLaunch_ < 10000) return false;   // tried recently; don't block typing
            lastLaunch_ = now;
            LaunchServer();
        }
        Sleep(100);
    }
    if (pipe_ == INVALID_HANDLE_VALUE) return false;
    DWORD mode = PIPE_READMODE_MESSAGE;
    SetNamedPipeHandleState(pipe_, &mode, nullptr, nullptr);
    return true;
}

static std::wstring Unescape(const std::string& v) {
    std::string out;
    for (size_t i = 0; i < v.size(); i++) {
        if (v[i] == '\\' && i + 1 < v.size()) {
            out += v[i + 1] == 'n' ? '\n' : v[i + 1];
            i++;
        } else {
            out += v[i];
        }
    }
    return Utf8ToWide(out);
}

EngineReply EngineClient::Request(const std::string& op, const std::string& arg) {
    EngineReply reply;
    std::string message = arg.empty() ? op : op + "\t" + arg;
    for (int attempt = 0; attempt < 2; attempt++) {   // once more after a broken pipe
        if (!Connect()) return reply;
        DWORD written = 0;
        if (!WriteFile(pipe_, message.data(), (DWORD)message.size(), &written, nullptr)) {
            Close();
            continue;
        }
        std::string data;
        char buf[4096];
        for (;;) {
            DWORD got = 0;
            BOOL ok = ReadFile(pipe_, buf, sizeof(buf), &got, nullptr);
            data.append(buf, got);
            if (ok) break;
            if (GetLastError() != ERROR_MORE_DATA) {
                Close();
                return reply;
            }
        }
        size_t start = 0;
        while (start <= data.size()) {
            size_t end = data.find('\n', start);
            if (end == std::string::npos) end = data.size();
            std::string line = data.substr(start, end - start);
            size_t eq = line.find('=');
            if (eq != std::string::npos) {
                std::string name = line.substr(0, eq), value = line.substr(eq + 1);
                if (name == "handled") reply.handled = value == "1";
                else if (name == "commit") reply.commit = Unescape(value);
                else if (name == "preedit") reply.preedit = Unescape(value);
                else if (name == "cursor") reply.cursor = atoi(value.c_str());
                else if (name == "cand") reply.candidates.push_back(Unescape(value));
                else if (name == "candsel") reply.candidateIndex = atoi(value.c_str());
                else if (name == "english") reply.english = value == "1";
                else if (name == "text") reply.text = Unescape(value);
                else if (name == "message") reply.message = Unescape(value);
                else if (name == "item") {
                    // "<id>\t<flags>\t<text>", or empty for a separator.
                    MenuItem item;
                    size_t t1 = value.find('\t'), t2 = t1 == std::string::npos ? t1 : value.find('\t', t1 + 1);
                    if (t2 != std::string::npos) {
                        item.id = atoi(value.substr(0, t1).c_str());
                        std::string flags = value.substr(t1 + 1, t2 - t1 - 1);
                        item.checked = flags.find('c') != std::string::npos;
                        item.enabled = flags.find('d') == std::string::npos;
                        item.text = Unescape(value.substr(t2 + 1));
                    }
                    reply.menu.push_back(item);
                }
            }
            start = end + 1;
        }
        return reply;
    }
    return reply;
}
