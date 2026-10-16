# 驗證範圍與重現方式

## 實機記錄

2026-10-05 曾於 macOS、SketchUp 26.2.242、內嵌 Ruby 3.2.2 完成九組整合驗證：

| 範圍 | 結果 |
|---|---|
| runtime、模型／選取／材質／tags／相機查詢 | 通過 |
| 群組、元件、面、推拉、盒體、mm/cm 與隔離 | 通過 |
| 變換、屬性與世界包圍盒 | 通過 |
| 過期 revision、錯誤模型與失效實體拒絕 | 通過 |
| 共用元件範圍及巢狀 copy-on-write | 通過 |
| Undo/Redo 與外部 operation 引起的 revision 變化 | 通過 |
| Ruby 模式拒絕、例外 abort、輸出序列化檢查 | 通過 |
| PNG 匯出與實際圖像檢視 | 通過 |
| 橋接啟停、目錄設定保留與 session 更新 | 通過 |

另完成模型切換／重開 token 更新、獨立 Python 程序建立及刪除 200 mm 盒體，以及完全重啟 SketchUp 後的外掛選單／管理器啟用狀態確認。

這些是單一 Mac 環境的歷史實測摘要；公開倉庫不含使用者模型、截圖、原始佇列、session 識別資料或帶個人路徑的原始報告。它們不代表在其他 SketchUp 版本或任意 Ruby 腳本上皆通過。CI 不會啟動 SketchUp。

## 獨立程序測試

```bash
ruby tests/test_transport.rb
python3 -m unittest discover -s tests -p 'test_*.py'
python3 scripts/package.py
```

Ruby 傳輸測試覆蓋去重、請求衝突、session／模型拒絕、半寫入、崩潰復原、目錄鎖、路徑邊界與日期驗證。Python 測試覆蓋逾時不重送、receipt 拒絕、路徑／數值檢查、發行包內容／checksum／重現性，以及安裝時保留既有 skill。0.1.1 增加中文／空白目錄、UTF-8 BOM、Windows 路徑與 junction 拒絕、跨程序目錄鎖、讀取時原子替換，以及實際 Ruby transport 與 Python 客戶端的跨程序 JSON 往返。互通測試使用 EchoAdapter，不模擬 SketchUp 建模成功。

## 重新執行 SketchUp 驗證

此腳本會建立測試幾何、寫入報告與 `.skp`，只在專用測試模型執行。先安裝本倉庫版本的 RBZ，再依序進行：

1. 在 SketchUp 另開全新的未儲存模型，使用專用的橋接目錄並啟用橋接。
2. 開啟 Ruby 控制台，確認目前是測試模型後執行：

   ```ruby
   Sketchup.active_model.set_attribute('CodexBridgeVerification', 'fixture', true)
   ```

3. 將以下路徑換成自己 checkout 的位置後執行：

   ```ruby
   load '/absolute/path/to/SketchUP_bridge/scripts/verify_in_sketchup.rb'
   ```

腳本要求未儲存且具有 fixture 標記的模型、已啟用的橋接，以及尚不存在 `verification/bridge-verification.skp`。報告輸出至 `verification/sketchup-results.json`，模型在同目錄；PNG 路徑寫入報告。重跑前自行移走上次的測試模型，避免覆寫。

此腳本包含測試用信任旗標切換，以驗證 Ruby 開關及失敗處理；結束恢復 false。它不屬於 skill 的一般建模流程，也不代表允許在正式模型繞過使用者的 Ruby 啟用選單。外部修改競爭以獨立 API operation 模擬，未用滑鼠完整繪製室內場景。

## 已知行為與限制

- 內嵌 Ruby 的 `require 'time'` 曾因缺少 `date_core` 失敗，外掛不使用此依賴。
- SketchUp 會移除空容器；外掛使用帶標記的隱藏 ConstructionPoint 保留，加入內容後清除。
- 實測 `SketchupExtension.load_on_start?` 曾回報 false，與實際自動載入不符；以管理器、選單和橋接回應判斷。
- 每次修改是一個 operation；多次請求不自動成為同一次 Undo。任意 Ruby 的檔案／程序副作用沒有撤銷保障。
- 修改要求根編輯層與選取工具；沒有 UI 背景執行、強制逾時或完整室內物件庫。0.1.1 加入 Windows 傳輸與客戶端相容處理，Windows SketchUp 實測仍待完成，見 [Windows 指南](windows.md)。
