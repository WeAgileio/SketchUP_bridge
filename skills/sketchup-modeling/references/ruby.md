# 受信任 Ruby 操作

在 actions 無法完成要求時使用 `execute_ruby`，例如參數化複雜幾何或鏡頭設定。先核對 SketchUp API 官方文件 `https://ruby.sketchup.com/` 對應類別及版本；不要只憑其他 Ruby 版本或猜測的 API 編寫。已驗證環境為 SketchUp 26.2.242／Ruby 3.2.2。

## 啟用與執行

讀心跳 `trusted_ruby`。false 時須由使用者在「擴展程式套件 → Codex SketchUp Bridge → 切換受信任 Ruby 模式」啟用；清楚說明腳本需要的操作。不要以設定 adapter 屬性、控制台 eval 或替換檔案繞過選單。重啟預設 false，capabilities 包含 execute_ruby 不等於模式已啟用。

arguments 含 `script` 字串，可另帶腳本使用的參數。binding 中提供 `model`（目前模型）、`args`（整個 arguments）及 `result`。以 JSON 序列化器從 Ruby 檔案與參數產生 args-file；不要在 shell 中直接拼接腳本。

腳本須將結果明確指定給 `result`。返回少量可核對資料，如 PID、尺寸或完成數量；只能包含 JSON 型別、字串鍵、有限數值，巢狀最多 64 層。不要返回 Sketchup::Entity、Point3d、Symbol 或其他 Ruby 對象。長度用 `.to_f` 並依回傳契約換算；取得實體後檢查型別與有效性。

例如讀取已知根層物件數量的最小腳本：

```ruby
result = { 'root_entity_count' => model.entities.length }
```

這只示範輸出格式；一般查詢直接用 model_info，不必為這個例子開啟 Ruby。execute_ruby 一律視為修改，需要明確的模型 token/revision、根編輯層與選取工具。

## Operation 與執行界線

橋接已包住 start_operation／commit_operation，錯誤時 abort。腳本**不要**自行開始、提交或撤銷 operation，也不要切換／關閉模型、顯示 modal、退出程序、建立背景工作或產生檔案／程序副作用。這是本外掛的可信腳本契約，沒有沙箱強制隔離；違反後不能保證 Undo。

依使用者目標執行有限、可預估的工作；大量幾何分成可檢查的批次。沒有強制中斷或硬性執行逾時。客戶端 TimeoutError 不會停止 Ruby；不要同時送第二段來「補做」。結果序列化失敗會 abort 模型 operation，但不能撤回外部副作用。

SketchUp API 的長度原生為 inch，可使用 `1000.mm` 等明確單位轉換。此內嵌環境曾在 require time 時缺 date_core；避免為一般格式化載入該依賴。

Ruby 直接往空容器加入內容後，如需移除橋接保留點，只清除該容器中帶 `get_attribute('CodexSketchupBridge', 'placeholder', false)` 的 ConstructionPoint，不刪其他參考點。

保存 `.skp`、匯入檔案等若涉及外部檔案，不透過任意 Ruby 擴大此契約；採用使用者授權的正常 SketchUp UI 工作流程。視圖 PNG 已有 `export_view` action。
