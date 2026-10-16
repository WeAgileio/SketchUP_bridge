# Windows SketchUp 2023 驗收記錄範本

狀態：待執行。請複製此範本填寫，不把待驗證欄位當成通過。

## 環境

- 日期／驗收人：
- Windows 版本與 build：
- SketchUp 完整版本：
- 內嵌 Ruby 完整版本：
- Python 完整版本：
- 外掛版本／來源提交／RBZ SHA256：
- 安裝與載入是否成功：
- 橋接使用一般本機資料夾（中文與空白）：

## 驗收證據

先依 windows.md 安裝，再依 verification.md 於獨立未儲存測試模型執行九組驗證。只保存測試模型；勿對使用者模型執行驗證腳本。

| 項目 | 結果（待執行／通過／失敗） | 證據檔案與錯誤 |
|---|---|---|
| runtime 與查詢 | 待執行 | |
| 群組、元件、面、推拉、盒體及單位隔離 | 待執行 | |
| 變換、屬性與世界包圍盒 | 待執行 | |
| 舊 revision、錯誤模型、失效實體拒絕 | 待執行 | |
| 共用元件與巢狀 copy-on-write | 待執行 | |
| Undo／Redo 與外部修改 revision | 待執行 | |
| Ruby 開關、abort 與序列化 | 待執行 | |
| PNG 匯出與圖像檢視 | 待執行 | |
| 啟停及 session 更新 | 待執行 | |
| 原生 Python model_info，核對正確模型 | 待執行 | |
| Python 建立 1200×600×750 mm 中文名稱盒體，核對尺寸 | 待執行 | |
| 單次 Undo 撤銷該請求，重新查詢 revision | 待執行 | |
| Python export_view，開啟 PNG 核對內容 | 待執行 | |
| UTF-8 BOM 參數檔、中文與空白路徑 | 待執行 | |
| 完全重啟後外掛選單存在，橋接未自動啟用 | 待執行 | |
| 重新啟用，新 session 查詢成功，舊 session 請求遭拒 | 待執行 | |
| 重啟後 trusted_ruby 為 false | 待執行 | |

Python 修改請求須使用剛查詢到的 model_token 與 revision，參數用 --args-file；檢查回應 status，不能只看程序結束碼。重啟測試只在測試模型用舊 session 的讀取請求驗證拒絕，不重送舊建模請求。

附上 verification/sketchup-results.json、客戶端回應、測試 PNG、測試模型與版本記錄。公開前去除個人路徑及識別資料。只有所有必要項目通過後，才能將該環境標示為已驗證；失敗項目保留原錯誤供重現。
