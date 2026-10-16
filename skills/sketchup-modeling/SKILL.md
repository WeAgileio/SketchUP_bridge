---
name: sketchup-modeling
description: "透過 Codex SketchUp Bridge 在 macOS／Windows SketchUp 2026 查詢、建立或修改實際模型，核對尺寸、處理群組與元件並匯出視圖。當使用者要求操作 SketchUp、依描述建模或調整既有模型時使用；適用室內設計及一般建模，不預設房型或流程。"
---

# SketchUp 建模

使用已安裝的 Codex SketchUp Bridge 0.1.1、協定 v1。優先經本機檔案佇列呼叫 Ruby API；使用者描述決定建模目標，模型查詢決定實際狀態。不要預設新建空模型、清除場景、房間尺寸、座標方向或物件分類。

## 連線與工具

此 skill 的 `scripts/bridge.py` 是外掛專案的 Python 標準函式庫客戶端副本，需 Python 3.9+。以目前 skill 的絕對位置呼叫，可在任意工作目錄使用；不用另外建立 MCP 伺服器。

先找出使用者指定或本次工作已確認的橋接目錄。若目前工作目錄含 `bridge-runtime/session.json`，可當候選位置；缺少位置資訊時詢問使用者實際選定的資料夾，不搜尋其他模型或默認某個人的家目錄。macOS 常見 app 位置是 `/Applications/SketchUp 2026/SketchUp.app`；Windows 依使用者安裝位置啟動 SketchUp。Windows 使用原生 Python（`py -3` 或 `python`），不要把 WSL 路徑直接傳給 Windows SketchUp；橋接選用一般本機資料夾，避開 junction、符號連結及同步目錄。

先讀取 `status`，再呼叫 `model_info`。以下 Bash 範例在 Windows PowerShell 改用 `py -3`，並將續行符 `\` 改成 PowerShell 的反引號或寫成單行。變數分別是此 skill 內 `scripts/bridge.py` 的絕對路徑、實際橋接目錄、以及查詢所得 token；執行前依環境設定，勿把 JSON 或 Ruby 腳本插值成 shell 程式碼。

```bash
python3 "$sketchup_client" --root "$sketchup_queue" status
python3 "$sketchup_client" --root "$sketchup_queue" call model_info
python3 "$sketchup_client" --root "$sketchup_queue" call list_entities --args '{"parent":[],"limit":100}' --model-token "$sketchup_model_token"
```

`status` 只讀取最後心跳，**不保證即時在線**。檢查 `enabled`、`heartbeat_at`、`capabilities`；一般提交會拒絕停用或超過 10 秒的心跳。心跳過期也可能是 Ruby 正在阻塞 UI，不代表請求未執行。

若尚未啟用，使用 SketchUp「擴展程式套件 → Codex SketchUp Bridge → 啟用橋接…」選擇專用目錄。每次 SketchUp 重啟需重新啟用橋接；目錄必須讓 SketchUp 和 Codex 都可讀寫。選單不存在時先確認 Extension Manager 的外掛開關。實測 26.2.242 的 `load_on_start?` 曾與 UI 不一致，應以實際選單、管理器與心跳判斷。不要靠重新安裝、調低安全設定或清除佇列來處理一般離線。

## 模型操作

先確認 `model_info` 的模型名稱、路徑、token，並依需求讀選取物件、父層內容、材質或相機。無標題模型不能只靠名稱辨識。既有資訊足夠就執行；只有目標、尺寸或修改範圍有實質歧義時才補問。

使用結構化操作前讀 [操作參數與座標](references/actions.md)。它列出此版本實際支援的 actions、JSON 範例、共用元件範圍及回傳內容。按需求組合操作，不套用固定室內建模順序。

- 使用查詢所得的 `path`／persistent ID；名稱可重複，不能作唯一識別。分頁沿 `next_offset` 讀取，必要時再進入指定父層。
- 每次修改明確傳入最近查詢或成功結果的 `model_token` 與 `revision`；同模型操作循序送出，不能同 revision 並行建模。CLI 雖會預設使用心跳值，skill 不依賴這個預設來修改。
- `stale_revision` 或模型切換後，重新查詢並重新判斷目標；不要只換成最新 revision 原樣重送。共用元件 copy-on-write 後重新取得 path。
- 此版本所有操作都要求退出群組／元件編輯；修改另要求「選取」工具。不要在使用者正在使用原生工具時反覆重試。
- 尺寸指定 `mm`、`cm`、`m` 或 `inch`。JSON 座標屬父層；世界包圍盒不一定等於旋轉物件的自身尺寸。

參數寫入 JSON 檔，命令參照檔案。以下 token/revision 必須取自實際模型，不能照抄示例值：

```bash
python3 "$sketchup_client" --root "$sketchup_queue" call create_box \
  --args-file "$sketchup_args_file" \
  --model-token "$sketchup_model_token" --expected-revision "$sketchup_revision"
```

CLI `call` 先印一行提交資訊（`request_id`、`receipt`、完整 request），再印結果 JSON；不能將整段 stdout 當單一 JSON。程式整合可匯入 `BridgeClient`，使用 `submit`、`wait` 並保存提交資訊。**程序 exit code 為 0 不代表模型操作成功**，以結果的 `status`、`error` 與 `warnings` 為準。

## 結果核對與恢復

成功後核對目標 path、尺寸／數量與回傳 revision；依視覺需求呼叫 `export_view`，用影像工具檢視回傳 PNG。不要只根據「請求已送出」宣告完成。回報已修改內容與尚未驗證部分；外掛不自動儲存 `.skp`，未另行保存就明確說明模型尚未儲存。

逾時只查原請求，不建立新 ID 重跑：

```bash
python3 "$sketchup_client" --root "$sketchup_queue" result "$sketchup_request_id" \
  --receipt "$sketchup_receipt" --timeout 30
```

保留 receipt 才能辨識此次提交是否被拒絕。`outcome_unknown` 或執行中斷代表結果未知，停止依賴該結果的修改並核對模型；不能當成未執行。相同 ID 只有完全相同請求才可去重，不能以新 session/revision 改寫原請求。清除完成紀錄會移除去重依據，不用它修復錯誤。

結構化修改各自是一個 Undo operation；例外通常 abort 當次 operation，多次請求不會自動合併為一次 Undo。`ambiguous_scope` 要釐清是否修改全部共用實例；`entity_missing` 要重新查詢；`locked_entity` 不自動解鎖；`file_exists` 改用新的匯出名稱。

## 需要更完整 Ruby API 時

當結構化 actions 無法表達使用者要求時，讀 [受信任 Ruby 操作](references/ruby.md)，依實際 API 設計腳本。不要把未支援 action 假裝成已實作功能。Ruby 模式須經使用者在外掛選單啟用，不能透過控制台直接改信任旗標繞過它。

skill 的客戶端與參數依 0.1.1 程式核對。Windows 客戶端／傳輸可自動測試，SketchUp 實機建模的驗證狀態須看專案記錄，不能由 CI 推定。若外掛升級或能力不同，以當前 `capabilities`、原始碼倉庫的 `docs/protocol.md` 與程式為準，同步更新 skill 客戶端；不要默認升級後仍相容。
