# Typefree (macOS)

**macOS 上的 AI 語音輸入法：按住快速鍵說話，放開後文字已經整理好、輸入至游標處。**

> 這個目錄（`mac/`）是 Typefree macOS 版的完整原始碼，以 GPL-3.0 開源。

## 本 Fork 最佳化項目

1. **繁體中文化**：全介面（狀態列選單、設定視窗、輔助面板、新手教學、權限引導）在地化為台灣繁體中文。
2. **擴充 BYOK（自備金鑰）生態**：
   - 語音辨識（Cloud ASR）：支援 **Groq**（Whisper Large v3 Turbo，超低延遲）、**OpenAI**（Whisper-1）、**Google Gemini**（Gemini 3.8 Flash / 3.5 Flash）、火山引擎（Volcengine BigASR）。
   - 語音潤色與隨時問 AI（Polish & Ask）：支援 **Google Gemini**（旗艦 Gemini 3.8 Flash）、**OpenAI**（GPT-4o-mini）、**Groq**（Llama 3.3 70B）、阿里雲百煉（通義千問）、智譜清言。
   - 辨識與潤色金鑰自動雙向連動，並加密安全儲存於 macOS 系統鑰匙圈（Keychain）。

## 能做什麼

- **說話變文字**：按住快速鍵（或滑鼠長按）說話，放開即辨識，AI 自動去除贅詞贅字、理順句子、分段、加標點，直接輸入到任何 App
- **長按問 AI**：在空白處長按說出問題，右上角面板給出回答，可續聊追問、可釘選固定
- **語音翻譯／口令**：句首或句尾說「用英文」直接輸出英文；支援日文、韓文、法文、德文、西班牙文等
- **個人詞庫與自動學習**：專有名詞、人名、產品名越用越準；改過的錯字下次自動糾正
- **歷史紀錄**：所有輸入本機加密保存，可搜尋、匯出 Markdown
- **多模型自由切換**：自由搭配你喜愛的辨識與潤色模型

## 自帶 Key（BYOK）

在「設定 → 模型」填入你自己的 API Key，**永久免費、不限字數**。費用直接走你自己的帳戶，Key 僅儲存在本機鑰匙圈：

- **Google Gemini**：[Google AI Studio 獲取 API Key](https://aistudio.google.com/app/apikey)
- **OpenAI**：[OpenAI API Keys 頁面](https://platform.openai.com/api-keys)
- **Groq**：[Groq Console API Keys](https://console.groq.com/keys)
- **火山引擎**：[火山引擎語音辨識主控台](https://console.volcengine.com/)
- **阿里雲百煉**：[百煉 API-KEY 管理](https://bailian.console.aliyun.com/)

## 從原始碼建置

需求：macOS 14.0+，Xcode 15+ / 16+（Swift 6）。

```bash
cd mac
./build.sh                       # 產物在 dist/Typefree Install.app
bash scripts/install_app.sh      # 安裝到 /Applications
```

也可以直接用 Xcode 打開 `VoicePolish.xcodeproj`，scheme 選擇 `VoicePolish`，簽名改為你自己的 Team 即可。

執行核心庫測試：

```bash
cd mac/VoicePolishCore && swift test
```

## 專案架構

- `Sources/` — macOS 選單列應用程式（AppKit + SwiftUI）
- `VoicePolishCore/` — 核心庫（錄音、雲端辨識、AI 潤色、詞庫、歷史紀錄加密），Swift Package
- `Resources/` — 應用程式圖示、entitlements、新手指南 HTML
- `build.sh` / `scripts/install_app.sh` — 本機建置與安裝指令稿

## 隱私承諾

- API Key 僅儲存於本機 macOS 鑰匙圈，絕不對外上傳
- 自備 Key 時，音訊直接傳送給對應模型服務商，不經過任何第三方中間伺服器
- 歷史紀錄全數於本機端加密儲存

## 授權條款

程式碼以 [GNU GPL-3.0](LICENSE) 開源。

