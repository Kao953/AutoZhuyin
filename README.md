# 自動注音 AutoZhuyin

macOS 繁體中文輸入法：**不用按切換鍵**，直接用大千注音鍵盤打字，輸入法會自動判斷你打的是注音還是英文。

```
按鍵： ji3 hello world su3cl3␣
輸出： 我hello world 你好
```

## 運作方式

每按一個鍵，`Classifier` 會同時用兩種解讀幫目前的按鍵序列打分：

| 注音分數 | 英文分數 |
|---|---|
| 是否能拆成合法注音音節（`SyllableTable`） | 是否為常用英文字（`english-common.txt`） |
| 每個音節有沒有聲調鍵（3 4 6 7 空白） | 是否在系統字典 `/usr/share/dict/words` |
| 讀音是否存在於詞庫 | 字母 bigram 模型判斷「像不像英文」 |
| 前一段是中文 → 加分（語境） | 前一段是英文 → 加分（語境） |
| 使用者過去的修正（學習） | 有大寫字母 → 一定是英文 |

分數高的一方勝出。組字區即時顯示結果（英文以藍字顯示）。

## 按鍵

| 按鍵 | 作用 |
|---|---|
| 空白 | 注音：一聲；音節已完成時送出中文。英文：送出單字加空白 |
| Enter | 送出目前組字 |
| **Tab** | 判斷錯了？按 Tab 在中／英之間翻轉，輸入法會**記住**這次修正 |
| ↓ | 開啟候選字（選最後一個字或詞），數字鍵 1–9 選字 |
| Esc | 取消組字 |
| Shift + 字母 | 強制英文 |
| `< > ? ! :` | 中文語境下自動轉成全形 `，。？！：` |

## 建置與安裝

需要 Xcode（使用 `/Applications/Xcode.app` 的工具鏈）。

```bash
swift test                # 執行單元測試（需 DEVELOPER_DIR 指向 Xcode）
scripts/build.sh          # 產生 build/AutoZhuyin.app
scripts/install.sh        # 安裝到 ~/Library/Input Methods 並重啟輸入法
```

第一次安裝後：系統設定 → 鍵盤 → 文字輸入 → 編輯… → ＋ → 繁體中文 → **自動注音**。
如果清單裡沒出現，登出再登入一次。

## 詞庫

`Resources/lexicon.txt` 由開源的小麥注音原始資料轉換而來（MIT 授權，約 17 萬筆），
後面再接上手寫的入門詞庫 `Resources/lexicon-seed.txt`。轉換只讀取資料檔，不執行小麥注音的程式碼。
要更新到小麥注音最新資料：

```bash
scripts/import-mcbopomofo.sh
scripts/install.sh
```

自訂詞：`~/Library/Application Support/AutoZhuyin/user-phrases.txt`，格式同 `lexicon.txt`：
`ㄗˋ-ㄉㄨㄥˋ-ㄓㄨˋ-ㄧㄣ 自動注音 -4`

## 專案結構

```
Sources/AutoZhuyinCore/     純邏輯，可單元測試
  Bopomofo.swift            大千鍵盤對應、音節結構
  SyllableTable.swift       合法注音音節表
  ZhuyinParser.swift        按鍵 → 音節
  Lexicon.swift             詞庫
  Converter.swift           音節 → 中文（Viterbi）
  EnglishModel.swift        英文判斷
  Classifier.swift          中英判斷 + 學習
  CompositionEngine.swift   輸入法狀態機
Sources/AutoZhuyin/         InputMethodKit 外殼
Tests/                      單元測試
```

## 下一步（Roadmap）

- [ ] 匯入完整詞庫，並用真實打字資料調整判斷權重
- [ ] 已送出的英文單字若判斷錯誤，可以「事後翻轉」
- [ ] 用 Core ML 小模型取代手調分數，參考整句語境
- [ ] 使用者詞頻學習（選過的候選字優先）
- [ ] 偏好設定視窗
