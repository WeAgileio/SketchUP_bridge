# SketchUP Bridge

讓 Codex 透過本機 Ruby API，在 **SketchUp 桌面版** 查詢、建立及修改實際模型。包含 SketchUp 外掛、Python 客戶端，以及可安裝的 **`$sketchup-modeling` skill**。適用室內設計與一般建模，不預設房型、尺寸或操作順序。

```text
你的建模需求 → Codex + skill → Python 客戶端
                                    ↓ 本機 JSON 佇列
                              SketchUp Ruby 外掛 → 模型與 PNG 回饋
```

不需要額外的 HTTP 服務或 MCP 伺服器。SketchUp 必須開啟建模視窗，並啟用橋接。

## 下載與需求

本次 `0.1.1` 為 **Windows SketchUp 2023 相容性候選版**，同時保留 macOS SketchUp 2026 的使用方式。Windows Ruby 2.7 CI 與 SketchUp 2023 實機結果仍待驗證，不能把候選版視為已完整驗收。

由本分支執行 `python scripts/package.py`（Windows 可用 `py -3`）產生：

- `dist/codex-sketchup-bridge-0.1.1.rbz`：SketchUp 外掛。
- `dist/sketchup-modeling-0.1.1.zip`：Codex skill。
- `dist/SHA256SUMS`：檔案校驗值。

既有 [Releases](https://github.com/WeAgileio/SketchUP_bridge/releases) 的 v0.1.0 不包含本次相容修改。

需求：Windows 桌面版 SketchUp 2023 或 macOS SketchUp 2026、原生 Python 3.9+、可存取本機檔案的 Codex。不需額外安裝 Ruby；SketchUp Web 不適用。請使用兩個程式均可存取的一般本機資料夾。詳見 [Windows 指南](docs/windows.md)、[相容性與測試狀態](docs/compatibility.md)。

## 安裝 SketchUp 外掛

1. 開啟 SketchUp 的「擴展程式套件 → 擴展程式管理器 → 安裝擴充程式」，選擇 RBZ。
2. 確認管理器中的 **Codex SketchUp Bridge** 已啟用。
3. 準備一個專用本機資料夾；例如在這個專案內執行 `mkdir -p bridge-runtime`。
4. 在「擴展程式套件 → Codex SketchUp Bridge → 啟用橋接…」選擇該資料夾。
5. 回到模型根編輯層並啟用「選取」工具，讓 Codex 使用相同資料夾。

每次重啟 SketchUp 都需重新啟用橋接。資料夾須讓 SketchUp 和 Codex 都可讀寫；若 Codex 有檔案存取限制，可使用其工作區內的資料夾。不要讓多台電腦經 iCloud 或其他同步服務共用同一佇列。

這是未簽署的本機開發外掛，安裝須符合 SketchUp 現有載入政策；程式不修改全域安全設定。

## 安裝 Codex skill

從原始碼安裝：

```bash
git clone https://github.com/WeAgileio/SketchUP_bridge.git
cd SketchUP_bridge
python3 scripts/install_skill.py
```

安裝程式使用 `$CODEX_HOME/skills`，未設定時使用 `~/.codex/skills`；遇到同名 skill 會停止，保留既有檔案。也可用 `--skills-dir` 指定位置。

若使用 ZIP，解壓縮後將完整 `sketchup-modeling` 資料夾放進同一 skills 目錄。開啟新的 Codex 聊天；若尚未出現，重新啟動 Codex 讓它重新讀取 skills。

在 Codex 中說：

> 使用 $sketchup-modeling，橋接資料夾是「我選定的絕對路徑」。先讀取目前模型，再依我的需求修改。

之後直接描述目標、尺寸或要改動的既有物件。Skill 會先查詢模型、確認目標與版本，再送出操作並核對結果。

## 客戶端與操作能力

也可直接使用 Python 客戶端，將 `<bridge-directory>` 換成實際絕對路徑：

```bash
python3 client/bridge.py --root '<bridge-directory>' status
python3 client/bridge.py --root '<bridge-directory>' call model_info
python3 client/bridge.py --root '<bridge-directory>' call list_entities --args '{"parent":[],"limit":100}'
```

支援模型／選取／材質／tags／相機查詢、群組／元件／面／盒體、推拉、變換、屬性、刪除及 PNG 匯出。修改必須使用查詢得到的模型 token 和 revision；詳細參數見 [協定文件](docs/protocol.md) 與 [skill 操作參考](skills/sketchup-modeling/references/actions.md)。

一般操作不需要受信任 Ruby 模式。特殊功能可由使用者在外掛選單啟用 `execute_ruby`，契約見 [Ruby 操作說明](skills/sketchup-modeling/references/ruby.md)。Ruby 沒有沙箱；外部副作用無法透過 Undo 還原，客戶端逾時也不會取消執行。

`status` 可能讀到舊心跳；`call` 的程序結束碼也不等於模型操作成功，須檢查結果的 `status`。逾時後查詢原 request_id／receipt，避免重複建模。橋接不會自動儲存或覆寫 `.skp`。

## 開發、測試與打包

```bash
ruby tests/test_transport.rb
python3 -m unittest discover -s tests -p 'test_*.py'
python3 scripts/package.py
```

Ruby 測試需要 `minitest`（若缺少，執行 `gem install minitest -v 5.25.5`）；外掛與 Python 客戶端本身不需要下載額外套件。

打包會檢查 skill 的客戶端副本與 `client/bridge.py` 一致，再產出 RBZ、skill ZIP 及 SHA256SUMS 到 `dist/`。GitHub Actions 已設定 Windows Ruby 2.7.2／2.7.8／3.2 與 macOS Ruby 3.2 測試組合，涵蓋 Python 3.9／3.11。需實際執行成功後才有對應結果與建置產物；CI 不執行 SketchUp GUI。實機驗證範圍及重現方式見 [驗證文件](docs/verification.md)。

```text
extension/                 SketchUp Ruby 外掛
client/bridge.py           Python CLI 與 BridgeClient
skills/sketchup-modeling/  可獨立安裝的 Codex skill
scripts/                   安裝、打包與實機驗證
tests/                     本機傳輸、客戶端與封裝測試
docs/                      協定及驗證說明
```

## 停用與移除

在外掛選單「停用橋接」，或使用 Extension Manager 停用／移除外掛。移除 skill 時只移除自己的 skills 目錄內 `sketchup-modeling`。模型與匯出影像不會自動刪除。

本專案沿用倉庫既有的 [MIT License](LICENSE)。
