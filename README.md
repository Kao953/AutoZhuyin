# 自動注音 AutoZhuyin

給繁體中文使用者的輸入法（macOS、Windows）：**不用按切換鍵**，直接用大千注音鍵盤打字，輸入法會自動判斷你打的是注音還是英文。

```
按鍵： ji3 hello world su3cl3␣
輸出： 我hello world 你好
```

## 功能

- **中英自動判斷**：每按一個鍵就重新判斷，組字區即時顯示結果（Mac 版英文以藍字顯示）
- **中英混打不用空白**：`ji3hello` → 我hello、`hellosu3cl3` → hello你好，同一段內會自動切分
- **判斷錯了按 Tab**：在中／英之間翻轉，輸入法會記住這組按鍵，下次自動判斷對
- **單按 Shift 切換英文模式**：英文模式下按鍵直接送出、保持小寫、不顯示底線，再單按一次 Shift 回到中英自動判斷
- **注音順序打錯也能修正**：`ㄧㄒㄠˇ`、`ㄒㄠㄧˇ` 都會變成 `ㄒㄧㄠˇ`（小）
- **可省略聲調**：`jiap7`（ㄨㄛ ㄇㄣ˙）一樣能打出「我們」
- **候選字**：用 ← → 把游標移到要改的字後面，按 ↓ 選字；選過的會固定下來
- **全形標點**：中文語境下 `?` `!` `<` 自動變成 `？` `！` `，`
- **完整詞庫**：約 17 萬筆，來自小麥注音 McBopomofo（MIT 授權）

## 下載與安裝

到 Gitea 的 [Releases](../../releases) 頁面下載最新版本。

### macOS

需求：macOS 13 以上，Apple Silicon 和 Intel 都可以（universal binary）。

1. 雙擊 `AutoZhuyin-<版本>.pkg` 安裝。安裝檔沒有簽章，如果被擋下來，按右鍵 →「打開」，或到「系統設定 → 隱私權與安全性」按「仍要打開」。
2. 系統設定 → 鍵盤 → 文字輸入 → 編輯… → ＋ → 繁體中文 → **自動注音**。
3. 清單裡沒出現的話，登出再登入一次。

PKG 會裝到 `/Library/Input Methods/`，系統上所有使用者都能用。

### Windows

需求：Windows 10 / 11，x64、x86、ARM64 都可以。

1. 先安裝輸入法框架 [PIME](https://github.com/EasyIME/PIME/releases)（免費、開源）。
2. 解壓縮 `AutoZhuyin-Windows-<版本>.zip`，在 `install.bat` 上按右鍵 →「以系統管理員身分執行」。
3. 設定 → 時間與語言 → 語言與地區 → 中文(台灣) → 語言選項 → 新增鍵盤 → **自動注音 AutoZhuyin**。
4. 用 Win + 空白鍵 切換過去。清單裡沒出現的話，重新開機一次。

SmartScreen 出現警告時，按「其他資訊 → 仍要執行」。解除安裝：以系統管理員身分執行 `uninstall.bat`。

## 按鍵

| 按鍵 | 作用 |
|---|---|
| 空白 | 注音：一聲；音節已完成時送出中文。英文：送出單字加空白 |
| Enter | 送出目前組字 |
| **Tab** | 判斷錯了？按 Tab 把整段翻轉成另一種語言，輸入法會**記住**這次修正 |
| ← → | 在組字區移動游標，選要改哪個字 |
| ↓ | 開啟游標前那個字或詞的候選字（游標預設在最後），數字鍵 1–9 選字，Esc 關閉 |
| Esc | 取消組字 |
| **單按 Shift** | 沒在打字時：切換**英文模式**，按鍵直接送出、保持小寫、沒有底線，一直維持到再單按一次 Shift 才回到中英自動判斷。打到一半時：同 Tab，整段翻轉 |
| Shift + 字母 | 打大寫字母（也會強制英文） |
| `< > ? ! : ( ) [ ]` | 中文語境下自動轉成全形 `，。？！：（）「」` |
| `, . / ; -` | 英文單字後是標點；在注音中是 ㄝ ㄡ ㄥ ㄤ ㄦ（例如 `2;3` = 檔） |

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

## 個人資料

| | macOS | Windows |
|---|---|---|
| 學習紀錄（Tab 修正） | `UserDefaults`（`com.autozhuyin.inputmethod.AutoZhuyin`） | `%APPDATA%\PIME\autozhuyin\learned.json` |
| 自訂詞 | `~/Library/Application Support/AutoZhuyin/user-phrases.txt` | `%APPDATA%\PIME\autozhuyin\user-phrases.txt` |

自訂詞的格式和 `lexicon.txt` 一樣，每行一個詞：`ㄗˋ-ㄉㄨㄥˋ-ㄓㄨˋ-ㄧㄣ 自動注音 -4`（讀音、詞、分數；分數越大越優先）。
Mac 版可以在輸入法選單選「清除學習紀錄」。

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
scripts/package-windows.sh                          # 產生 build/AutoZhuyin-Windows-<版本>.zip（會先跑測試）
```

- Windows 沒有內建英文字典，所以 `build_data.py` 會把 macOS 的 `/usr/share/dict/words`（韋氏字典，公有領域）轉成 `english-dict.txt` 一起打包，並預先算好 bigram 表。
- `windows/autozhuyin/data/` 是產生出來的，不進版本控制。
- 版本號在 `windows/autozhuyin/ime.json`。

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

| | 送出時整段判斷正確 | 打字過程中顯示正確 |
|---|---|---|
| 手調權重 | 97.58% | 86.15% |
| 訓練後 | **99.62%** | 87.81% |

送出時的錯誤率從 2.4% 降到 0.4%。「打字過程中」本來就有歧義（例如 `ji3h` 的 `h` 可能是英文的開頭，也可能是注音 ㄘ），所以準確率比較低，但最後送出的結果才是重點。

新增特徵時，Swift 和 Python 兩邊都要加，預設權重設成 0，然後重新訓練。

### 詞庫

`Resources/lexicon.txt` 由小麥注音的原始資料轉換而來，後面再接上手寫的入門詞庫 `Resources/lexicon-seed.txt`。轉換程式 `scripts/convert-mcbopomofo.py` 只讀取資料檔，不執行小麥注音的程式碼：分數依語料詞頻計算，一字多音的字依讀音常見程度分配權重。

更新到小麥注音最新資料：

```bash
scripts/import-mcbopomofo.sh
```

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
3. 產生 `build/AutoZhuyin-<版本>.pkg` 和 `build/AutoZhuyin-Windows-<版本>.zip`
4. commit「Release v<版本>」並打上 `v<版本>` tag

任何一步失敗都會把版本號改回去。只想改版本號不打包：`scripts/bump-version.sh [patch|minor|major]`。

最後在 Gitea 用這個 tag 建立 Release，附上 `build/` 裡的 `.pkg` 和 `.zip`。

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
  installer/                  install.bat、uninstall.bat、給使用者的 README.txt
  tests/                      Python 測試
  tools/                      產生資料檔、圖示
training/                     合成資料、訓練權重、Swift/Python 一致性測試資料
```

## 已知限制

- Windows 版還沒在實機上測試過。
- 聲調鍵打在注音符號中間（例如 `uv3l`）無法自動修正。
- 很短的字串（如 `up` 是英文還是 ㄧㄣ）本質上就有歧義，可能需要按 Tab 修正；修正後會記住。
- 安裝檔沒有簽章（macOS 沒有 Developer ID，Windows 沒有程式碼簽章憑證）。

## 下一步（Roadmap）

- [x] 匯入完整詞庫
- [x] 注音順序錯誤修正
- [x] Windows 版
- [x] 用資料訓練判斷權重（合成資料）
- [ ] 加入真實打字資料一起訓練
- [ ] 已送出的英文單字若判斷錯誤，可以「事後翻轉」
- [ ] 用 Core ML 小模型取代手調分數，參考整句語境
- [ ] 使用者詞頻學習（選過的候選字優先）
- [ ] 偏好設定視窗

## 致謝與授權

- 詞庫資料：[小麥注音 McBopomofo](https://github.com/openvanilla/McBopomofo)（MIT License）
- Windows 輸入法框架：[PIME](https://github.com/EasyIME/PIME)（LGPL 2.1，使用者自行安裝，本專案不包含其程式碼）
- 英文字典：Webster's Second International Dictionary（公有領域，macOS 的 `/usr/share/dict/words`）
