# 自動注音 AutoZhuyin

給繁體中文使用者的輸入法（macOS、Windows、Linux）：**不用按切換鍵**，直接用大千注音鍵盤打字，輸入法會自動判斷你打的是注音還是英文。

```
按鍵： ji3 hello world su3cl3␣
輸出： 我hello world 你好
```

## 功能

- **中英自動判斷**：每按一個鍵就重新判斷，組字區即時顯示結果（Mac 版英文以藍字顯示）
- **中英混打不用空白**：`ji3hello` → 我hello、`hellosu3cl3` → hello你好，同一段內會自動切分
- **判斷錯了按 Tab**：在中／英之間翻轉，輸入法會記住這組按鍵，下次自動判斷對；已經按空白送出了也可以，緊接著按 Tab 就會改掉剛送出的字
- **單按 Shift 切換英文模式**：英文模式下按鍵直接送出、保持小寫、不顯示底線，再單按一次 Shift 回到中英自動判斷；切換時游標旁會短暫顯示「A」或「中」（Windows、Linux 的輸入法圖示也會變成「A」）
- **注音順序打錯也能修正**：`ㄧㄒㄠˇ`、`ㄒㄠㄧˇ` 都會變成 `ㄒㄧㄠˇ`（小）
- **可省略聲調**：`jiap7`（ㄨㄛ ㄇㄣ˙）一樣能打出「我們」
- **候選字**：用 ← → 把游標移到要改的字後面，按 ↓ 選字；選過的會固定下來
- **記住選字**：從候選字選過的字詞會被記住，下次打同樣的讀音會優先出現（選越多次越優先）
- **AI 選字**：用中研院 CKIP 的繁中小型語言模型看前後文挑同音字（他跑「得」很快、請你「再」說一次），完全在本機運算；可調整或關閉，系統忙碌時自動暫停
- **中間補字、刪字**：游標移到前面後直接打注音，會插在游標處；Backspace 刪掉游標前的那個字
- **全形標點**：中文語境下 `?` `!` `<` 自動變成 `？` `！` `，`；`\` 在中文語境下是 `、`；`Ctrl` + `; ' , . /` 直接打出 `；、，。？`；任何時候按 `` ` `` 再按標點鍵，一定得到全形標點（例如 `` `< `` = `，`）；`` ` `` 再按空白會打開符號表
- **完整詞庫**：約 17 萬筆，來自小麥注音 McBopomofo（MIT 授權）

## 下載與安裝

到 GitHub 的 [Releases](../../releases) 頁面下載最新版本。

### macOS

需求：macOS 13 以上，Apple Silicon 和 Intel 都可以（universal binary）。

1. 雙擊 `AutoZhuyin-<版本>.pkg` 安裝。安裝檔沒有簽章，如果被擋下來，按右鍵 →「打開」，或到「系統設定 → 隱私權與安全性」按「仍要打開」。
2. 系統設定 → 鍵盤 → 文字輸入 → 編輯… → ＋ → 繁體中文 → **自動注音**。
3. 清單裡沒出現的話，登出再登入一次。

從 0.13.x 更新：0.13 把輸入法拆成「中英自動」和「英文」兩個項目，0.14 起改回單一個「自動注音」。更新後如果輸入法清單裡沒有「自動注音」，到「系統設定 → 鍵盤 → 輸入方式」重新加入即可。

PKG 會裝到 `/Library/Input Methods/`，系統上所有使用者都能用。

### Windows

需求：Windows 10 / 11，x64、x86、ARM64 都可以。

1. 執行 `AutoZhuyin-Windows-<版本>-setup.exe`。電腦上還沒有輸入法框架 [PIME](https://github.com/EasyIME/PIME)（免費、開源）的話，安裝程式會一起裝好（附的是 PIME 1.3.0 正式版）。這個一鍵安裝程式是**實驗功能**，還沒在實機上測過，有問題請改用下面的 zip 手動安裝並回報。
   ARM 處理器的電腦要先自己安裝 [PIME 2.0 以上](https://github.com/EasyIME/PIME/releases)，安裝程式會提示。
2. 設定 → 時間與語言 → 語言與地區 → 中文(台灣) → 語言選項 → 新增鍵盤 → **自動注音 AutoZhuyin**。
3. 用 Win + 空白鍵 切換過去。清單裡沒出現的話，重新開機一次。

SmartScreen 出現警告時，按「其他資訊 → 仍要執行」。解除安裝：「設定 → 應用程式」裡的「自動注音 AutoZhuyin」（PIME 會留著，不需要的話另外移除）。
也可以用 zip 版手動安裝：先裝好 PIME，解壓縮 `AutoZhuyin-Windows-<版本>.zip`，以系統管理員身分執行 `install.bat`（移除用 `uninstall.bat`）。

**獨立版（實驗）**：`AutoZhuyin-Windows-Standalone-<版本>-setup.exe` 不需要 PIME，自帶輸入法元件和 Python，需要 64 位元的 Windows 10 / 11。在鍵盤清單裡叫「自動注音（獨立版）」，可以和 PIME 版同時安裝。還沒在實機上測過；目前沒有設定選單（AI 選字固定「標準」，自訂詞直接改 `%APPDATA%\AutoZhuyin\user-phrases.txt`，存檔後馬上生效），Microsoft Store 類的 App（例如開始功能表的搜尋）裡可能打不出字。學習紀錄和自訂詞在 `%APPDATA%\AutoZhuyin`。

### Linux（Bazzite、SteamOS 桌面模式、Fedora…）

需求：系統內建 IBus 輸入法框架（Bazzite、Fedora 預設就有）。只在桌面模式可用，Steam 遊戲模式不支援系統輸入法。

1. 解壓縮 `AutoZhuyin-Linux-<版本>.tar.gz`，在終端機進到資料夾執行 `./install.sh`。不需要 sudo，只會裝在家目錄（`~/.local/share/autozhuyin`），所以唯讀系統也能用。
2. KDE（Bazzite / SteamOS 預設）：系統設定 → 鍵盤 → 虛擬鍵盤，選 **IBus Wayland** → 套用，登出再登入。GNOME 不用設定。
3. 之後每次登入會自動切換到自動注音（`~/.config/autostart/autozhuyin.desktop`）。

暫時改回一般鍵盤：`ibus engine xkb:us::eng`；切回：`ibus engine autozhuyin`；移除：`./uninstall.sh`。

## 按鍵

| 按鍵 | 作用 |
|---|---|
| 空白 | 注音：一聲；音節已完成時送出中文。英文：送出單字加空白 |
| Enter | 送出目前組字 |
| **Tab** | 判斷錯了？按 Tab 把整段翻轉成另一種語言，輸入法會**記住**這次修正。**已經按空白送出了**也可以：緊接著按 Tab，剛送出的字會被換成另一種語言（`so ` → 內，`su3cl3` 被打成你好 → `su3cl3 `），再按一次換回來。只限按空白送出後的下一個鍵；按 Enter 送出的不算（之後的 Tab 通常是要補完或縮排），中間打了別的字、移動游標或點了別處也是一般的 Tab。Mac、Linux 和 Windows 獨立版可用（程式要支援讀取游標前文字）；Windows 的 PIME 版做不到（PIME 不能讀取或刪除已送出的字） |
| ← → | 在組字區移動游標（最左停在第一個中文字後面）。游標在中間時：直接打注音會**插入**新字，Backspace 刪掉游標前的字，↓ 選游標前的字 |
| ↓ | 開啟游標前那個字或詞的候選字（游標預設在最後），數字鍵 1–9 選字，Esc 關閉 |
| Esc | 取消組字 |
| **單按 Shift** | 沒在打字時：切換**英文模式**（Mac 的終端機 App，例如 Terminal、iTerm2、Warp、Ghostty、kitty，一開始就是英文模式，要打中文時單按 Shift 切回），按鍵直接送出、保持小寫、沒有底線，一直維持到再單按一次 Shift 才回到中英自動判斷，Mac 會在游標旁短暫顯示「A」/「中」，Windows 的工作列和 Linux 的 IBus 狀態圖示會變成「A」；Mac 也可以從輸入法選單的「英文模式」切換。打到一半時：同 Tab，整段翻轉 |
| Shift + 字母 | 打大寫字母（也會強制英文） |
| `< > ? ! : ( ) [ ] \` | 中文語境下自動轉成全形 `，。？！：（）「」、` |
| `Ctrl` + `; ' , . /` | 不管前後文，直接打出 `；` `、` `，` `。` `？`（打到一半會先送出組字） |
| `` ` `` + 空白（或 ↓） | **符號表**：列出常用全形符號（`、；：「」『』（）《》〈〉…——～・【】`、數學符號、箭頭、`○●☆★` 等），用數字鍵或方向鍵加 Enter 選。前面是英文時 `` ` `` + 空白仍是普通的反引號加空白（Markdown 的 `` `code` `` 照常可用），這時用 `` ` `` + ↓ 開符號表 |
| `, . / ; -` | 英文單字後是標點；在注音中是 ㄝ ㄡ ㄥ ㄤ ㄦ（例如 `2;3` = 檔） |
| `` ` `` + 標點鍵 | **強制全形標點**，不管前後是中文還是英文：`` `, `` `` `< `` = `，`、`` `. `` `` `> `` = `。`、`` `/ `` = `？`、`` `; `` = `；`、`` `: `` = `：`、`` `' `` `` `\ `` = `、`、`` `[ `` `` `] `` = `「」`、`` `{ `` `` `} `` = `『』`、`` `( `` `` `) `` = `（）`、`` `! `` = `！`、`` `~ `` = `～`、`` `- `` = `——`、`` `= `` = `＝`。`` ` `` 後面接其他鍵就是普通的反引號（` ``` ` 照常可用） |

## 運作方式

每按一個鍵，`Classifier` 會同時用兩種解讀幫目前的按鍵序列打分：

| 注音分數 | 英文分數 |
|---|---|
| 是否能拆成合法注音音節（`SyllableTable`） | 是否為常用英文字（`english-common.txt`） |
| 每個音節有沒有聲調鍵（3 4 6 7 空白） | 是否在英文字典裡 |
| 讀音是否存在於詞庫 | 字母 bigram 模型判斷「像不像英文」 |
| 前一段是中文 → 加分（語境） | 前一段是英文 → 加分（語境） |
| 使用者過去的修正（學習） | 有大寫字母 → 一定是英文 |
| 一開始稍微偏向注音 | 純數字 → 數字 |

每一項都是一個**特徵**（`Features.swift` / `features.py`），分數 = 特徵 × **權重**。權重是用資料訓練出來的（見下方「訓練判斷權重」），存在 `Resources/classifier-weights.json`；檔案不存在時用手調的預設值。分數高的一方勝出。按空白時，還沒打聲調的注音音節會當成一聲來評分，英文那邊當作完整單字評分。

中英混打時，`Classifier.segment` 會用動態規劃試遍所有切分點，找出總分最高的切法（例如 `ji3hello` → `ji3` 注音＋`hello` 英文）。為了避免把正常的單字或句子切碎：
- 每多切一刀會扣分（`seg.switch` 特徵）
- 後面還接著其他段的注音段，最後一個音節必須打了聲調
- 接在英文後面、還沒打聲調的注音段會再扣分（`zh.unconfirmed`），所以打到 `ji3hel` 時會先顯示「我hel」，不會變成「我heㄠ」

音節解析照大千規則：符號依「聲母 → 介音 → 韻母」填入，聲調鍵結束音節。順序打錯時，如果合併後仍可能是合法音節，就併進同一個音節，否則才切成新音節。

轉換用 Viterbi 演算法，在詞庫中找出整串音節機率最高的詞組組合。

### AI 選字

詞庫只知道每個詞本身有多常見，不看前後文。AI 選字讓語言模型當裁判：

1. 詞庫先找出前 K 名的整句組合（例如「請你在說一次」「請你再說一次」）。
2. 模型 [CKIP GPT2-tiny](https://huggingface.co/ckiplab/gpt2-tiny-chinese)（中研院詞庫小組，繁體中文，約 1200 萬參數，22 MB）計算每個組合出現的機率，並參考剛送出的前文。
3. 分數 = 詞庫分數 + 0.6 × 模型分數，取最高的。選過的候選字仍然固定不變。

輸入法選單可以調整（Mac：選單列的輸入法選單；Windows：工作列輸入法圖示按右鍵或語言列的設定按鈕；Linux：IBus 選單的「設定」）：

| 模式 | 比較幾個組合 | 每次運算上限 |
|---|---|---|
| 關閉 | — | 不載入模型、不佔記憶體 |
| 省電 | 3 | 15 毫秒 |
| 標準（預設） | 10 | 40 毫秒 |
| 高品質 | 30 | 120 毫秒 |

不會拖慢打字的機制：
- 每次運算超過上限就直接放棄，改用詞庫結果；連續 3 次超時就暫停一分鐘。
- 「系統忙碌時自動暫停 AI」（預設開啟），選單裡會顯示目前狀態：

| | 暫停 AI | 降到省電模式 |
|---|---|---|
| macOS | 過熱，或 CPU 負載（每核心 1 分鐘平均）超過 0.9 | 低耗電模式 |
| Windows | CPU 使用率超過 90% | 省電模式（電池保護） |
| Linux | CPU 負載超過 0.9，或溫度達 95 °C | 低耗電設定檔，或用電池且電量 ≤ 20% |
- 模型在背景載入，載入完成前照常用詞庫。

實測（`training/lm/eval_rerank.py`，標準模式）：

| 測試資料 | 只用詞庫 | AI 選字 |
|---|---|---|
| 日常對話 60 句 | 字正確率 96.6%，整句全對 73% | 97.5%，80% |
| 維基百科 714 句 | 92.9%，31% | 94.7%，44% |

錯字大約少了 25–30%。

Windows、Linux 版用 numpy 執行同一個模型（`windows/autozhuyin/core/lm.py`），所以時間上限放寬為省電 40、標準 80、高品質 200 毫秒，超時的那次結果照用但不快取，連續 3 次超時暫停一分鐘。
- Windows：安裝包附上 PIME 兩種 Python（1.3 版的 3.8、2.x 版的 3.15，都是 32 位元）用的 numpy，安裝檔約 40 MB。
- Linux：系統沒有 numpy 時，`install.sh` 會從 PyPI 下載符合的版本到 `~/.local/share/autozhuyin/vendor/`。
- 設定存在 `%APPDATA%\PIME\autozhuyin\settings.json`、`~/.config/autozhuyin/settings.json`。

## 個人資料

| | macOS | Windows | Linux |
|---|---|---|---|
| 學習紀錄（Tab 修正） | `UserDefaults`（`com.autozhuyin.inputmethod.AutoZhuyin`） | `%APPDATA%\PIME\autozhuyin\learned.json` | `~/.config/autozhuyin/learned.json` |
| 選字紀錄 | `~/Library/Application Support/AutoZhuyin/user-history.json` | `%APPDATA%\PIME\autozhuyin\user-history.json` | `~/.config/autozhuyin/user-history.json` |
| 自訂詞 | `~/Library/Application Support/AutoZhuyin/user-phrases.txt` | `%APPDATA%\PIME\autozhuyin\user-phrases.txt` | `~/.config/autozhuyin/user-phrases.txt` |

輸入法選單的「編輯自訂詞…」：
- Mac、Linux：打開編輯視窗。打好詞會自動填入常用讀音（可以改，注音符號或大千鍵位都行），按加入就生效；用這個視窗加入的詞分數是 -1，會排在同讀音的內建詞前面。表格裡的詞和注音可以直接點兩下修改。
- Windows（PIME 版）：用記事本打開自訂詞檔（第一次會附上格式說明），存檔後下次切換到輸入法時生效，看不懂的行會提示行號。

自訂詞的格式和 `lexicon.txt` 一樣，每行一個詞：`ㄗˋ-ㄉㄨㄥˋ-ㄓㄨˋ-ㄧㄣ 自動注音 -4`（讀音、詞、分數；分數越大越優先）。自訂詞會蓋過內建詞庫裡同一個詞、同一個讀音的分數。直接改檔案也可以，三個平台都會自動重新讀取。
選字紀錄最多保留 2000 筆，太久沒用的會先淘汰。被選過的字只會排到同讀音第一順位，不會蓋過整個詞組（例如選過「添」之後，ㄊㄧㄢ 單打會出「添」，但「今天」還是「今天」）。
輸入法選單的「清除學習紀錄」會把中英判斷和選字紀錄一起清除（Windows 獨立版沒有選單，刪除上面的檔案即可）。

## 開發

### macOS

需要 Xcode。腳本會自動使用 `/Applications/Xcode.app` 的工具鏈。

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcrun swift test          # 單元測試
scripts/build.sh          # 產生 build/AutoZhuyin.app（universal）
scripts/install.sh        # 裝到 ~/Library/Input Methods、重啟並向系統註冊
scripts/package.sh        # 產生 build/AutoZhuyin-<版本>.pkg
```

改完程式後執行 `scripts/install.sh`，再切換到其他輸入法後切回來，就會用到新版。
版本號在 `Resources/Info.plist` 的 `CFBundleShortVersionString`。

### Windows

Windows 版建立在 [PIME](https://github.com/EasyIME/PIME) 上，核心邏輯用 Python 重寫（`windows/autozhuyin/core/`），行為和測試案例都跟 Mac 版一樣。不需要 Windows 也能開發和測試：

```bash
python3 windows/tools/build_data.py                 # 產生 windows/autozhuyin/data/
(cd windows && python3 -m unittest discover tests)  # 核心測試 + 模擬 PIME 的外殼測試
scripts/package-windows.sh                          # 產生 build/AutoZhuyin-Windows-<版本>.zip 和 -setup.exe（會先跑測試）
```

- Windows 沒有內建英文字典，所以 `build_data.py` 會把 macOS 的 `/usr/share/dict/words`（韋氏字典，公有領域）轉成 `english-dict.txt` 一起打包，並預先算好 bigram 表。
- `windows/autozhuyin/data/` 是產生出來的，不進版本控制。
- 版本號在 `windows/autozhuyin/ime.json`。

獨立版（實驗，不用 PIME）是自己寫的 TSF 輸入法元件：

- `windows/tsf/src/`：C++ DLL，載入到每個 App 裡，只負責按鍵、組字底線和候選字視窗。用 mingw-w64 在 macOS 上交叉編譯（`scripts/build-tsf.sh`，x64 和 x86 各一份，32 位元的 App 用 x86 版）。
- `windows/tsf/server.py`：引擎伺服器，每個使用者一個行程，用內附的 64 位元內嵌版 Python 執行同一份 Python 核心，DLL 透過 named pipe `\\.\pipe\AutoZhuyin-<使用者>` 和它溝通（協定見檔案開頭）。登入時啟動，沒在跑的話 DLL 會自己叫起來；出錯時寫到 `%APPDATA%\AutoZhuyin\server-error.log`。
- `scripts/package-windows-standalone.sh`：產生 `build/AutoZhuyin-Windows-Standalone-<版本>-setup.exe`（需要 `brew install mingw-w64 makensis`）。協定的測試在 `windows/tests/test_tsf_server.py`。

### Linux

Linux 版是 IBus 輸入法（`linux/autozhuyin_ibus.py`），直接使用 Windows 版的 Python 核心（`windows/autozhuyin/core/`）和資料。

```bash
python3 -m unittest discover -s linux/tests   # 用假的 IBus 模組測試外殼
scripts/package-linux.sh                       # 產生 build/AutoZhuyin-Linux-<版本>.tar.gz（會先跑測試）
```

- 安裝在使用者目錄，不寫入 `/usr`：開機時由 autostart 啟動 `autozhuyin_ibus.py --activate`，它會把引擎動態註冊給 ibus-daemon 並切換過去。
- 也支援由 ibus-daemon 啟動（`--ibus`，配合 `/usr/share/ibus/component` 的 XML），之後要做 RPM 時可以用。

> 修改核心邏輯時，Swift（`Sources/AutoZhuyinCore/`）和 Python（`windows/autozhuyin/core/`）兩邊都要改，並在兩邊的測試加上相同案例。

### 訓練判斷權重

中英判斷的權重是用合成資料訓練的（結構化感知器，averaged structured perceptron），訓練時跑的就是輸入法實際使用的同一套切分演算法：

1. `training/synth.py` 產生打字資料：從詞庫依詞頻抽中文詞，反查成大千按鍵；英文從常用字表和字典抽；組成「純中文、純英文、中＋英、英＋中、中＋英＋中、數字」等情況，每個按鍵都標好正確答案。也會產生「打到一半」的版本，用來訓練打字過程中的顯示。
2. `training/train.py` 先用手調權重評估一次，再訓練、評估，寫入 `Resources/classifier-weights.json`。
3. `training/make_parity.py` 產生 `training/parity-fixtures.json`，Swift 測試會檢查它的切分結果和 Python 版完全一樣。

```bash
python3 windows/tools/build_data.py     # 準備資料（Python 版和訓練共用）
python3 training/train.py               # 快速訓練（預設 3000 筆，約半分鐘）
python3 training/train.py --train 20000 --test 5000 --epochs 10   # 正式版本用的設定，約 3 分鐘
python3 training/train.py --eval-only   # 只評估目前的權重
python3 training/make_parity.py         # 權重或特徵改了之後都要重跑
```

目前的結果（10,000 筆測試資料）：

| | 送出時整段判斷正確 | 打字過程中顯示正確 | 跟前一個字語言不同時 |
|---|---|---|---|
| 手調權重 | 97.84% | 88.19% | 96.2% |
| 訓練後 | **99.52%** | **91.49%** | **99.3%** |

訓練資料也模擬了「前一個字是中文或英文」和「按下空白（一聲）的那一刻」，所以「前一個字」的影響（`ctx.zh` / `ctx.lit`）也是訓練出來的，不是手調的。「打字過程中」本來就有歧義（例如 `ji3h` 的 `h` 可能是英文的開頭，也可能是注音 ㄘ），所以準確率比較低，但最後送出的結果才是重點。

新增特徵時，Swift 和 Python 兩邊都要加，預設權重設成 0，然後重新訓練。

### 詞庫

`Resources/lexicon.txt` 由小麥注音的原始資料轉換而來，後面再接上手寫的入門詞庫 `Resources/lexicon-seed.txt`。轉換程式 `scripts/convert-mcbopomofo.py` 只讀取資料檔，不執行小麥注音的程式碼：分數依語料詞頻計算，一字多音的字依讀音常見程度分配權重。

更新到小麥注音最新資料（要在 Mac 上執行）：

```bash
scripts/update-lexicon.sh                          # 抓資料、列出差異、重產 parity fixtures、跑測試，確認後 commit
scripts/update-lexicon.sh && scripts/release.sh --push   # 更新詞庫後直接發修正版
```

`update-lexicon.sh` 會列出新增、刪除和分數變動的詞，問你 y/N 才 commit（`-y` 跳過確認）。詞庫沒有變動就直接結束。只想轉換不測試：`scripts/import-mcbopomofo.sh`。

### AI 選字模型

```bash
scripts/fetch-lm.sh     # 下載 CKIP gpt2-tiny-chinese，轉成 build/lm/lm.bin（float16）＋ lm-vocab.txt
```

`build.sh` 會自動執行並把模型打包進 app。模型推論寫在 `Sources/AutoZhuyinCore/LanguageModel.swift`（Accelerate，Apple Silicon 和 Intel 都可用），重排在 `Reranker.swift`。

評估效果（需要 numpy；`build/lm-eval/` 放測試句子，一行一句）：

```bash
python training/lm/eval_rerank.py build/lm-eval/chat.txt build/lm-eval/wiki.txt
```

`training/lm/gpt2.py` 是 numpy 版的參考實作，Swift 版的測試會比對它算出的分數。

### 發布新版本

先 commit 所有修改，再執行：

```bash
scripts/release.sh            # 修正版：0.1.0 → 0.1.1
scripts/release.sh minor      # 新功能：0.1.1 → 0.2.0
scripts/release.sh major      # 大改版：0.2.0 → 1.0.0
scripts/release.sh minor --push   # 同時 push commit 和 tag
```

`release.sh` 會自動：
1. 遞增版本號（`Resources/Info.plist` 的版本與 build 號、`windows/autozhuyin/ime.json`）
2. 跑 Swift 和 Python 全部測試
3. 產生 `build/AutoZhuyin-<版本>.pkg`、`build/AutoZhuyin-Windows-<版本>-setup.exe`、`build/AutoZhuyin-Windows-<版本>.zip`、`build/AutoZhuyin-Linux-<版本>.tar.gz`（Windows 安裝程式用 NSIS 打包：`brew install makensis`）
4. commit「Release v<版本>」並打上 `v<版本>` tag

任何一步失敗都會把版本號改回去。只想改版本號不打包：`scripts/bump-version.sh [patch|minor|major]`。

tag push 到 GitHub 之後，GitHub Actions（`.github/workflows/release.yml`）會在 macOS 機器上重跑測試、建置三個平台的安裝檔，並自動建立 Release 附上 `.pkg`、`-setup.exe`、`.zip`、`.tar.gz` 和 `SHA256SUMS.txt`。tag 必須和 `Info.plist` 的版本一致（例如 `v0.15.0`）。

也可以在 GitHub 的 Actions → Release → Run workflow 手動執行：填入既有的 tag 就會補建那一版的 Release；留空則只試建 `main`，產出的檔案放在該次執行的 Artifacts，不會發布。

## 專案結構

```
Sources/AutoZhuyinCore/       核心邏輯（Swift，可單元測試）
  Bopomofo.swift              大千鍵盤對應、音節結構
  SyllableTable.swift         合法注音音節表
  ZhuyinParser.swift          按鍵 → 音節（含順序錯誤修正）
  Lexicon.swift               詞庫
  Converter.swift             音節 → 中文（Viterbi）
  EnglishModel.swift          英文判斷
  Features.swift              判斷用的特徵與預設權重
  Classifier.swift            中英判斷（特徵 × 權重）、切分、學習
  CompositionEngine.swift     輸入法狀態機
Sources/AutoZhuyin/           macOS InputMethodKit 外殼
Tests/                        Swift 單元測試
Resources/                    Info.plist、詞庫、英文常用字、訓練好的權重
scripts/                      建置、安裝、打包、詞庫轉換
  pkg/postinstall             PKG 安裝後腳本
windows/
  autozhuyin/                 PIME 輸入法（整個資料夾會被複製到 PIME）
    core/                     核心邏輯（Python 版）
    autozhuyin_ime.py         PIME 外殼
    ime.json                  PIME 輸入法設定
  installer/                  setup.nsi（一鍵安裝程式）、install.bat、uninstall.bat、給使用者的 README.txt
  tests/                      Python 測試
  tools/                      產生資料檔、圖示
  tsf/                        獨立版（實驗）：TSF 元件原始碼（src/）、引擎伺服器、安裝程式
linux/
  autozhuyin_ibus.py          IBus 外殼（共用 windows/autozhuyin/core）
  installer/                  install.sh、uninstall.sh、給使用者的 README.txt
  tests/                      用假 IBus 模組的外殼測試
training/                     合成資料、訓練權重、Swift/Python 一致性測試資料
LICENSE                       本專案授權（GPL-3.0）
THIRD_PARTY_LICENSES.txt      第三方授權聲明（會打包進三個平台的安裝檔）
```

## 已知限制

- Windows 版、Linux 版還沒在實機上測試過。
- Linux 版只支援 IBus。KDE 上有些 Flatpak 程式（例如 Flatpak 版 Chrome）在 IBus Wayland 下可能打不出字。
- 聲調鍵打在注音符號中間（例如 `uv3l`）無法自動修正。
- 很短的字串本質上就有歧義。開頭第一個詞如果也能讀成注音，按空白後會先保留（顯示成英文），看下一個詞再決定：`up jo4` = 因為、`el ji3` = 高我、`no su3cl3` = no 你好、`up the` = up the。接在英文後面時只保留 `up`（因）這種很常見的讀音，不會拖慢打英文。還是判斷錯的話按 Tab 修正，修正後會記住。
- 安裝檔沒有簽章（macOS 沒有 Developer ID，Windows 沒有程式碼簽章憑證）。

## 下一步（Roadmap）

- [x] 匯入完整詞庫
- [x] 注音順序錯誤修正
- [x] Windows 版
- [x] Linux 版（IBus）
- [ ] Linux Fcitx5 版（KDE 上相容性較好）
- [x] 用資料訓練判斷權重（合成資料）
- [ ] 加入真實打字資料一起訓練
- [x] 已送出的英文單字若判斷錯誤，可以「事後翻轉」（macOS、Linux、Windows 獨立版；PIME 版做不到）
- [x] AI 選字：語言模型參考前後文挑同音字（macOS、Windows、Linux）
- [x] 使用者詞頻學習（選過的候選字優先）
- [ ] 偏好設定視窗（已有自訂詞編輯：macOS、Linux 是視窗，Windows 用記事本）

## 致謝與授權

本專案以 [GNU General Public License v3.0](LICENSE) 授權釋出。

- 詞庫資料：[小麥注音 McBopomofo](https://github.com/openvanilla/McBopomofo)（MIT License）
- Windows 輸入法框架：[PIME](https://github.com/EasyIME/PIME)（LGPL 2.1；setup.exe 內附未修改的官方 PIME 1.3.0 安裝程式，授權在 `licenses/PIME-LICENSE.txt`、`licenses/LGPL-2.1.txt`）
- 英文字典：Webster's Second International Dictionary（公有領域，macOS 的 `/usr/share/dict/words`）
- AI 選字語言模型：[CKIP GPT2 Tiny Chinese](https://github.com/ckiplab/ckip-transformers)（中研院詞庫小組，GPL-3.0，全文在 `licenses/GPL-3.0.txt`，並一起打包進三個平台的安裝檔）
- 數值運算：[NumPy](https://numpy.org)（BSD 3-Clause，Windows 版附上、Linux 版安裝時下載）

完整的第三方授權聲明（含小麥注音 MIT 授權全文）見 [THIRD_PARTY_LICENSES.txt](THIRD_PARTY_LICENSES.txt)，Mac 版放在 `AutoZhuyin.app/Contents/Resources/`，Windows 版放在 zip 根目錄和安裝後的 `autozhuyin` 資料夾。
