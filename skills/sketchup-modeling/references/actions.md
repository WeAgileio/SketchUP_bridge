# 結構化操作與座標

適用 Codex SketchUp Bridge 0.1.0／協定 v1。所有 arguments 是 JSON object；每份請求上限 1 MiB。下表只列客戶端可送的 action，UI 操作與任意 Ruby 不自動成為 action。

## 查詢與匯出

| action | arguments | data 重點 |
|---|---|---|
| `model_info` | `{}` | model_token、revision、title、path、bounds、axes；輸出長度 mm |
| `selection` | `{}` | entities，根編輯層目前選取物件 |
| `list_entities` | parent，offset 預設 0，limit 1–500 | entities、total、next_offset；末頁為 null |
| `materials` | `{}` | materials：name、color、alpha、texture 檔名 |
| `tags` | `{}` | tags：name、visible |
| `definitions` | `{}` | definitions：persistent_id、name、instances、bounds |
| `camera` | `{}` | eye、target、up、perspective、fov；只查詢相機 |
| `export_view` | filename 可省略，width/height 各 64–4096 | 已存在且非空的 PNG 絕對 path |

`list_entities.parent` 省略時為 `[]`（模型根層）。沿 `next_offset` 查下一頁；如果期間 revision 改變，不能把多頁當同一瞬間的快照。必要時重新查詢。

PNG 預設隨機名稱、1200 × 900，寫入橋接目錄 `exports/`。自訂 filename 僅英數、底線、連字號與 `.png`，不能傳路徑或覆寫既有檔案。匯出的是目前視角；需要改鏡頭時用 UI 或已啟用的 Ruby。

## 建立與修改

建立操作必須明確傳 `parent`；修改傳非空 `path`。每層為正整數 persistent ID，例如 `[父元件ID, 子群組ID, 面ID]`，不是名稱或定義 ID。

| action | arguments |
|---|---|
| `create_group` | parent、name 可選、scope 視共用情況 |
| `create_component` | parent、name、definition_name 可選、scope |
| `create_face` | parent、unit、points（3–10000 個 XYZ）、scope |
| `create_box` | parent、unit、origin、size（皆正的 XYZ）、name 可選、scope |
| `pushpull` | 面的 path、unit、distance、scope |
| `transform` | 群組／元件 path、mode、unit 及對應參數、scope |
| `set_properties` | path、name／material／tag 至少一個有意義的變更、scope |
| `delete_entities` | path、scope；每次一個目標 |

`transform` 以父層座標套用相對變換，不是指定絕對位置：

- translate：`vector: [x,y,z]`
- rotate：`origin: [x,y,z]`、`axis: [x,y,z]`、`degrees`；axis 是方向、不乘尺寸單位。
- scale：`origin`、`factors: [sx,sy,sz]`；倍率不能為 0。

`create_box` 建立獨立群組；`create_face` 加入指定父層，可能與同層幾何相連。需要隔離時先建立容器，再使用回傳 path。

建立 1200 × 600 × 750 mm 盒體的**格式範例**，不作任何使用者模型的預設尺寸：

```json
{"parent":[],"unit":"mm","origin":[0,0,0],"size":[1200,600,750],"name":"範例物件"}
```

`set_properties.material` 可為 null（清除指派），或物件：

```json
{"path":[123],"material":{"name":"此物件專用材質","color":[210,200,185],"alpha":1.0},"tag":"使用者指定分類"}
```

123 僅為示意，執行時替換為查詢的 path。同名 material 或 tag 會重用，未存在則建立。更新既有材質顏色會影響所有使用處；需要局部效果時使用新材質名稱。name 須目標支援，通常用於群組／元件。

## 共用內容與幾何回傳

修改共用元件內的內容時指定：

- `scope: "instance"`：共用祖先 make_unique 後修改該分支。
- `scope: "definition"`：修改共用定義內容，其他實例也會改變。

依使用者要求判定範圍，不能為了消除錯誤而盲選 definition。對元件實例本身移動／命名與修改它的內部幾何不同；影響範圍取決於目標路徑的共用祖先。copy-on-write 可能改變子 ID，之後採回傳新 path 並重查相關內容。鎖定目標或祖先會拒絕。

大部分修改回傳 `data.entity`；刪除回傳 `data.deleted_path`。entity 含 persistent_id、path、type、名稱、材質、tag，以及：

- parent_bounds：父層座標軸向包圍盒，mm。
- world_bounds：模型世界座標軸向包圍盒，mm；旋轉後不能直接視為物件自身長寬高。
- definition_bounds：容器定義座標包圍盒，mm。
- transform：SketchUp 原生 16 元素矩陣，平移部分為 inch；不能直接當 mm。

空群組／元件靠隱藏 ConstructionPoint 保留，參考點帶 `bridge_placeholder: true`；不是室內模型的設計物件。結構化操作加入內容後會移除該標記點。重新查詢時不要把它計入設計幾何。
