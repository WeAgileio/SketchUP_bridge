# 相容性核對與證據

本次來源基底為 main `6e9f08d`，整合 Windows 分支 `e6ebe2c` 中經審查的修改；候選版為 0.1.1。這份文件區分靜態核對、自動化及實機結果，不以歷史實測推定新包已驗收。

## 程式核對

| 範圍 | 核對與處理 |
|---|---|
| Ruby 語法 | 外掛使用安全導航、關鍵字參數、Hash／Array 操作，未使用 Ruby 3 專屬語法；2.7 執行仍由 CI 驗證 |
| 標準函式庫 | json、securerandom、digest、fileutils 均屬 2.7 標準函式庫；不依賴 time／date 或外部 native gem |
| 平台檔案旗標 | NOFOLLOW／O_NOFOLLOW 改為能力檢查，Windows 二進位 I/O 明確設定 |
| 編碼 | Ruby JSON 讀入指定 UTF-8，Python 參數檔接受 UTF-8 BOM，CLI 固定 UTF-8 |
| 路徑與 junction | Python 檢查 reparse 屬性；Ruby 2.7.2 原始碼已處理 junction 的 mount-point tag，維持 symlink? 檢查，不新增 FFI；Windows 實際測試待執行 |
| 檔案替換 | Windows EACCES／EPERM 最多重試十次，每次 20ms；其他平台直接回報，僅重試檔案操作 |
| UI | select_directory 自 2015 提供；計時器、選單及訊息框未依賴新版介面 |
| 實體識別 | persistent_id 自 2017 提供；所用群組、元件定義識別在 2023 之前已有 |
| 群組與元件 | Group#definition 自 2015 提供；make_unique、entities、to_component、transform! 不需 2023 之後 API |
| 模型與觀察者 | 使用既有 entities、active_path、axes、start/commit/abort_operation 與 transaction／active-path／AppObserver 回呼；未發現 2023 之後才有的呼叫，通知時序須實機驗證 |
| 圖像匯出 | write_image 的 options hash 自 SketchUp 7 提供，transparent 自 8；不使用較新 framebuffer 或螢幕座標功能 |
| 材質與標籤 | 使用既有 color、alpha、texture、layers；未使用 PBR 或新材質 API |
| 建模 | add_group、add_face、add_cpoint、pushpull、平移／旋轉／縮放與 bounding box；沒有新增版本專屬建模 API，尺寸、copy-on-write 與 Undo 仍須實測 |

靜態檢查沒有找到需要分叉建模邏輯的 API；本次集中修正傳輸，不把這項結論當成實機成功。

## 驗證狀態

| 環境／範圍 | 本次狀態 |
|---|---|
| macOS ARM64，Ruby 3.4.5／Python 3.9.6 | 本機自動化結果見下方紀錄 |
| Windows Ruby 2.7.2／Python 3.9 | CI 已設定，尚未執行 |
| Windows Ruby 2.7.8／Python 3.11 | CI 已設定，尚未執行 |
| Windows Ruby 3.2／Python 3.11 | CI 已設定，尚未執行 |
| macOS Ruby 3.2／Python 3.11 | CI 已設定，尚未執行 |
| Windows SketchUp 2023 內嵌 Ruby | 實機待驗收 |
| macOS SketchUp 2026，候選包 0.1.1 | 本次實機回歸待驗收；0.1.0 的歷史記錄見 verification.md |

CI 固定 Windows runner 為 windows-2022，Ruby 舊版本選 2.7.2 與 2.7.8，測試依賴固定 minitest 5.25.5（需求 Ruby >=2.7）。RubyInstaller 與 SketchUp 內嵌 Ruby 的編譯環境不同，CI 不替代 SketchUp 驗收。其他版本組合沒有自動取得已驗證狀態。

## 來源

- [SketchUp Ruby 版本紀錄](https://ruby.sketchup.com/file.ReleaseNotes.html)
- [UI](https://ruby.sketchup.com/UI.html)、[Entity](https://ruby.sketchup.com/Sketchup/Entity.html)、[Group](https://ruby.sketchup.com/Sketchup/Group.html)
- [Model](https://ruby.sketchup.com/Sketchup/Model.html)、[ModelObserver](https://ruby.sketchup.com/Sketchup/ModelObserver.html)、[AppObserver](https://ruby.sketchup.com/Sketchup/AppObserver.html)、[View](https://ruby.sketchup.com/Sketchup/View.html)
- [Ruby 2.7.2 Windows 原始碼](https://github.com/ruby/ruby/blob/v2_7_2/win32/win32.c)：reparse_symlink、rb_w32_read_reparse_point
- [setup-ruby 平台說明](https://github.com/ruby/setup-ruby)、[Windows Ruby 可用版本](https://github.com/ruby/setup-ruby/blob/master/windows-versions.json)
- [minitest 5.25.5 runtime 需求](https://rubygems.org/gems/minitest/versions/5.25.5)

## 本次本機結果（2026-10-16）

環境：macOS ARM64，Ruby 3.4.5，Python 3.9.6。

- `ruby tests/test_transport.rb`：16 項、60 個斷言，0 失敗／0 錯誤。
- `python3 -m unittest discover -s tests -p 'test_*.py'`：12 項，11 項通過，1 項 Windows junction 測試依平台跳過。
- extension 與 scripts 下六個 Ruby 檔案語法檢查通過。
- CI YAML 可解析，包含四組 runtime；`git diff --check` 通過。
- Python 測試包含 RBZ／技能 ZIP 內容、SHA256 及重現性；建模 API 不在這些測試內。

Windows Ruby 與 SketchUp 實測均未在本次執行；沒有推送分支或觸發遠端 CI。macOS 2026 候選包也尚未安裝，既有模型未用於測試。
