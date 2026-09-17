<p align="center">
  <img src="readme-assets/icon.png" width="96" height="96" alt="Typefree">
</p>

<h1 align="center">Typefree</h1>

<p align="center"><b>macOS 上的 AI 語音輸入：按住說話，放開時文字已經整理好、輸入至游標處。</b></p>

<p align="center">
  <a href="https://github.com/biantai34/typefree/releases/latest"><img src="https://img.shields.io/github/v/release/biantai34/typefree?label=%E6%9C%80%E6%96%B0%E7%89%88&color=1d1d1f" alt="最新版"></a>
  <a href="mac/LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0-1d1d1f" alt="GPL-3.0"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-1d1d1f" alt="macOS 14+">
</p>

<p align="center">
  <a href="https://github.com/biantai34/typefree/releases/latest"><b>下載 Mac 版</b></a> ·
  <a href="README.en.md">English</a>
</p>

<p align="center">
  <img src="readme-assets/zh-mouse.gif" width="768" alt="在輸入框裡按住滑鼠說話，放開後整理好的文字自動輸入；向下拖曳鎖定，拖遠取消">
</p>

## 本 Fork 最佳化亮點

- 🇹🇼 **全介面繁體中文化**：符合台灣在地語言習慣（設定、快速鍵、貼上、游標、儲存、鑰匙圈、辨識、麥克風、視窗）。
- 🔑 **全新 BYOK（自備金鑰）支援非大陸使用者常用服務**：
  - **Google Gemini**：語音辨識（Gemini 2.5 Flash 音訊轉寫）與語音潤色／隨時問 AI（Gemini 2.5 Flash）。
  - **OpenAI**：語音辨識（Whisper-1）與語音潤色／隨時問 AI（GPT-4o-mini）。
  - **Groq**：極速語音辨識（Whisper Large v3 Turbo，低延遲首選）與語音潤色（Llama 3.3 70B）。
  - 同時保留原有的火山引擎（Volcengine）、阿里雲百煉通義千問（DashScope Qwen）、智譜清言（Zhipu GLM）。
- 🔒 **鑰匙圈安全儲存**：API Key 儲存於 macOS Keychain，不落盤、絕不外洩。

## 它做什麼

在任何 App 的輸入框裡，按住快速鍵或滑鼠左鍵說話。放開後，辨識出的口語會被 AI 去除贅字贅詞（「嗯、啊、那個」），理順句子、加上標點和分段，然後直接輸入到游標處。說一句是一句，無需手動修潤。

- **說話變文字**：辨識 + AI 整理一步到位，LINE、備忘錄、瀏覽器、程式碼編輯器皆可使用
- **滑鼠長按說話**：不想按快速鍵，就在輸入框裡按住滑鼠；說一半想放開，向下拖曳一點鎖定；不想要了，拖遠取消
- **隨時問 AI**：在空白處按住滑鼠說出問題，回答出現在螢幕右上角，可追問、可固定
- **語音翻譯**：說完正文，結尾加一句「用英文」，這句直接輸入成英文；日文、韓文同理
- **越用越準**：專有名詞、人名、產品名自動學習；改過的錯字下次自動糾正
- **歷史紀錄**：所有輸入在本機加密保存，可搜尋、可匯出
- **彈性模型**：辨識支援 Groq、OpenAI、Gemini、火山引擎，潤色支援 Gemini、OpenAI、Groq、通義千問等，隨心搭配

## 自備 Key（BYOK）使用說明

在「設定 → 模型」填入你自己的 API Key，**永久免費、不限字數**，費用直接走你自己的帳戶：

| 服務商 | 支援項目 | 特點與推薦 | 申請連結 |
|---|---|---|---|
| **Google Gemini** | 辨識 + 潤色 | 免費額度充裕，Gemini 2.5 Flash 速度快且理解能力強（**強烈推薦**） | [Google AI Studio](https://aistudio.google.com/app/apikey) |
| **OpenAI** | 辨識 + 潤色 | Whisper 辨識精準，GPT-4o-mini 潤色穩定可靠 | [OpenAI Platform](https://platform.openai.com/api-keys) |
| **Groq** | 辨識 + 潤色 | Whisper Large v3 Turbo 極致秒開轉錄，極速輸出體驗（**強烈推薦**） | [Groq Cloud Console](https://console.groq.com/keys) |
| **火山引擎** | 辨識 + 潤色 | 大陸地區熱門服務，支援大模型語音辨識 | [火山引擎控制台](https://console.volcengine.com/) |
| **阿里雲百煉** | 辨識 + 潤色 | 通義千問（Qwen3 / Qwen-Plus） | [百煉平台](https://bailian.console.aliyun.com/) |

> 在設定頁面中輸入任一供應商的金鑰，系統會自動在辨識與潤色欄位同步，並自動儲存至 macOS 系統鑰匙圈。

## 隨時問 AI

<p align="center">
  <img src="readme-assets/zh-ask.gif" width="768" alt="在空白處按住滑鼠提問，回答出現在右上角；按住面板追問；點外面收起">
</p>

看到不懂的，不用切換視窗、不用複製，在空白處按住滑鼠問一句。按住回答面板可以接著問；點面板外面它會縮成一行、幾秒後消失，想保留就點圖釘。

## 語音翻譯

<p align="center">
  <img src="readme-assets/zh-translate.gif" width="768" alt="說完正文，結尾加一句「用英文」，這句直接輸入成英文">
</p>

口令由程式規則辨識，不靠模型猜測：預設支援英文、日文、韓文、中文，法語、德語、西班牙語可在設定中開啟。也可以固定一種輸出語言，無需每次說口令。

## 隱私承諾

- API Key 僅儲存於本機 macOS 鑰匙圈，絕不進行任何雲端上傳
- 音訊直接傳送至你設定的 API 服務商，絕無第三方中間伺服器
- 歷史紀錄全數於本機端加密儲存

## 從原始碼建置

需求：macOS 14+、Xcode 15+ / 16+。

```bash
git clone https://github.com/biantai34/typefree.git
cd typefree/mac
./build.sh                      # 產物在 dist/
bash scripts/install_app.sh     # 安裝至 /Applications
```

## 授權條款

本專案程式碼以 [GNU GPL-3.0](mac/LICENSE) 開源。

