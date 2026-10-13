# Windows 安裝與驗收

0.1.1 提供 Windows 檔案傳輸與客戶端相容處理。**Windows CI 通過不代表 Windows SketchUp 建模已驗證**；後者需要桌面版 SketchUp 的實機結果。已發布的 v0.1.0 仍是原 macOS 版本，不應用它判斷 Windows 相容性。

## 準備

- Windows 上可正常開啟的 SketchUp 2026 桌面版，以及原生 Windows Python 3.9+。
- 使用本分支 GitHub Actions 的 Windows 建置產物，或以 `py -3 scripts/package.py` 產生 0.1.1 RBZ 與 skill ZIP。
- 選擇本機一般資料夾作為橋接目錄，包含中文或空白亦可。不要使用 OneDrive 同步資料夾、junction、符號連結、網路磁碟或 WSL 路徑。

RBZ 在 SketchUp 的 Extension Manager 安裝；skill ZIP 解壓縮至 Codex 的 skills 目錄。從原始碼安裝 skill 可在 PowerShell 執行：

```powershell
py -3 scripts/install_skill.py
```

預設安裝至目前 Windows 使用者家目錄的 `.codex\skills`；若有 `CODEX_HOME`，使用其 `skills` 子目錄。遇到同名 skill 會停止，先保留既有版本再決定如何更新。

## 建立連線

在有寫入權限的專案目錄中執行：

```powershell
New-Item -ItemType Directory -Force bridge-runtime
$queue = (Resolve-Path .\bridge-runtime).Path
py -3 client/bridge.py --root "$queue" status
```

首次還沒有 session.json 時，先到 SketchUp 的 Codex SketchUp Bridge 選單啟用橋接，選擇同一目錄，再執行 status。回到模型根層與選取工具後：

```powershell
py -3 client/bridge.py --root "$queue" call model_info
```

確認結果 `status` 為 success、模型名稱／路徑正確、Ruby 和 SketchUp 版本有回傳。status 指令只讀最後心跳，不能代替這一步。

PowerShell 參數建議使用 `--args-file`，避免內嵌 JSON 引號差異。UTF-8 及 UTF-8 BOM 均可，UTF-16 參數檔不支援。客戶端輸出為 UTF-8。

## SketchUp 實機驗收

1. 先保存自己的模型，另開專用的未儲存測試模型並啟用橋接。
2. 依 [實機驗證步驟](verification.md#重新執行-sketchup-驗證) 執行 `scripts/verify_in_sketchup.rb`；Windows Ruby 路徑可用 `C:/.../SketchUP_bridge/scripts/verify_in_sketchup.rb` 的正斜線寫法。
3. 檢查九組結果全部通過，開啟輸出的 `.skp` 及 PNG，核對 1200 × 600 × 750 mm 盒體、巢狀元件與材質。
4. 另外以 Python client 完成 model_info、建模、結果查詢及 export_view；確認一次 Undo 撤銷一個請求。
5. 完全結束並重開 SketchUp，確認外掛選單仍在；重新啟用橋接後舊 session 請求應拒絕，新查詢應成功。確認受信任 Ruby 恢復關閉。

驗收記錄應包含 Windows、SketchUp、Ruby 版本，九組 JSON 結果、跨程序 client 回應及重啟結果。報告可能含模型路徑，公開分享前去除個人資訊。這些結果完成前，Windows 狀態維持「傳輸相容測試通過，SketchUp 實測待完成」。

## 相容處理依據

- Python 的部分檔案旗標視平台而定，不能直接假設存在 `O_NOFOLLOW`：[Python os 文件](https://docs.python.org/3.11/library/os.html#os.O_NOFOLLOW)。
- Windows 的檔案共享模式會影響替換操作；讀取心跳時允許刪除共享：[Microsoft CreateFileW](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-createfilew)。
- Ruby、SketchUp API 與執行環境版本須分別核對：[SketchUp Ruby API release notes](https://ruby.sketchup.com/file.ReleaseNotes.html)。
