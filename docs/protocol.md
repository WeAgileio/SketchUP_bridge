# 本機協定 v1

每個目錄只允許一個 SketchUp 實例。外掛啟用後以 0.5 秒週期寫入 `session.json` 心跳並取出一個請求。Ruby API 全部在主執行緒呼叫。檔案最大 1 MiB；大量實體使用分頁。此版本只處理已退出群組編輯、選取工具啟用的修改，避免原生工具正在操作或編輯座標差異。

## 工作目錄

- `inbox/<receipt>.json`：完整請求，以暫存檔原子 rename 提交。
- `processing/<receipt>.json`：正處理請求。
- `results/<request_id>.json`：原請求結果，不被 ID 衝突覆寫。
- `rejections/<receipt>.json`：提交格式、過期 session 或 ID 衝突等拒絕。
- `journal/<request_id>.json`：執行前持久化 claimed，結果發布後 done。
- `exports/*.png`：視圖匯出，不覆寫既有檔案。
- `bridge.lock`：程序持有 flock，崩潰由 OS 釋放。

客戶端等待時先檢查 receipt 拒絕結果；若該 receipt 仍在 inbox/processing，不能把同 ID 的舊結果當成此次提交結果。去重指紋忽略 submitted_at，其他欄位均納入。重啟 claimed 且沒有結果時標記 outcome_unknown，不重跑。手動清除紀錄後不再提供舊 ID 的去重保障。

## 請求

```json
{
  "protocol_version": 1,
  "request_id": "example-box-001",
  "session_id": "從心跳取得",
  "model_token": "從模型查詢取得",
  "expected_revision": 0,
  "action": "create_box",
  "arguments": {"parent": [], "unit": "cm", "origin": [0,0,0], "size": [120,60,75], "name": "示例"},
  "submitted_at": "2026-10-05T06:00:00Z"
}
```

request_id 為 1–80 個英數、底線或連字號；其他識別值以實際連線為準。model_token 對當次開啟生命週期有效，expected_revision 為非負整數，修改時必須與當前狀態一致。讀取允許 revision 變化，但仍核對模型 token。查詢後修改必須傳查詢取得的 token/revision，不可盲目使用新心跳繞過一致性檢查。

## 結果

```json
{
  "protocol_version": 1,
  "request_id": "example-box-001",
  "session_id": "工作階段",
  "model_token": "請求的模型",
  "current_model_token": "執行結束的模型",
  "revision": 1,
  "status": "success",
  "data": {"entity": {"persistent_id": 123, "path": [123]}},
  "warnings": [],
  "error": null,
  "completed_at": "2026-10-05T06:00:01Z"
}
```

data 依 action 定義，例中的 entity 為節錄。status 為 success、rejected、error 或 outcome_unknown；error 含 code、message、type（復原結果可能無 type）。心跳含 protocol_version、session_id、enabled、heartbeat_at、pid、model_token、revision、sketchup_version、ruby_version、trusted_ruby、capabilities。

## 操作參數

| action | arguments |
|---|---|
| model_info / selection / materials / tags / definitions / camera | `{}` |
| list_entities | parent（預設 []）、offset（預設 0）、limit（1–500，預設 100） |
| create_group / create_component | parent、name；元件可指定 definition_name；scope 如需要 |
| create_face | parent、unit、points（3–10000 個 XYZ）、scope 如需要 |
| create_box | parent、unit、origin、size（正值 XYZ）、name、scope 如需要 |
| pushpull | path、unit、distance、scope 如需要 |
| transform | path、mode；translate 使用 unit/vector；rotate 使用 unit/origin/axis/degrees；scale 使用 unit/origin/factors |
| set_properties | path、name、material（null 或 name/color/alpha 物件）、tag、scope 如需要 |
| delete_entities | path（一次一個實體）、scope 如需要 |
| execute_ruby | script（在 binding 中可用 model、args、result） |
| export_view | filename（英數底線連字號 .png，預設 UUID）、width/height（64–4096） |

parent/path 從模型根開始，每一層以 persistent_id 識別；輸入尺寸必須指定 mm、cm、m 或 inch。座標與變換使用父層座標，不預設北向或房型。輸出 bounds 為 mm 的軸向包圍盒，旋轉後世界包圍盒不等同物件自身尺寸；transform 矩陣為 SketchUp 原生格式，平移部分以 inch 表達。parent_bounds 是父層座標，world_bounds 轉換到模型世界座標，definition_bounds 是元件定義座標。

SketchUp 會自動清除空容器，因此 create_group/create_component 會先放入隱藏的 ConstructionPoint，並以 bridge_placeholder 標示；透過結構化指令加入內容後自動移除。Ruby 腳本直接加入內容時可自行清除帶該 attribute 的定位點。

scope 為 instance（對共用祖先 copy-on-write）或 definition（修改共用內容）。拷貝後子實體 ID 可能變化，應使用回傳新 path 並重新查詢。修改前會拒絕鎖定的目標或祖先。設定同名材質的色彩會改變該材質的其他使用處；若只想修改一個物件，使用新的材質名稱。

## Ruby 契約與限制

Ruby 模式需由使用者在選單啟用；重啟後預設關閉。腳本是完整本機 Ruby，無沙箱。腳本將輸出指定給 `result`，只允許 JSON 可表示型別、字串鍵、有限數值及最多 64 層巢狀。外掛在 commit 前檢查結果格式，例外則 abort 模型操作。

禁止腳本自行 start/commit/abort_operation、切換模型、UI modal、退出程序、長期背景工作與檔案／程序副作用。這是可信腳本契約而非強制隔離，違反契約無法保證撤銷。無硬性逾時與強制中斷；客戶端逾時不代表取消。不要將 Ruby 來源或任何 JSON 當作 shell 字串插值執行。

## 錯誤

常見 code：invalid_request、unsupported_version、stale_session、request_id_conflict、model_mismatch、stale_revision、entity_missing、ambiguous_scope、editing_context、native_tool_active、locked_entity、invalid_arguments、invalid_geometry、ruby_disabled、invalid_result、result_too_large、invalid_path、file_exists、export_failed、execution_error、directory_busy、outcome_unknown。

檔案佇列沒有防禦同帳號惡意程序的保證；目錄與資料為使用者可存取，session_id 防止誤投遞。不要讓兩台機器使用 iCloud 同步的同一佇列。實機驗證範圍與限制見 [驗證文件](verification.md)。
