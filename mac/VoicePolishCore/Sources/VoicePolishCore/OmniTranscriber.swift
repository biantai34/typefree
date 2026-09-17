import Foundation

/// Qwen Omni 一步直出：把录音样本直接喂给多模态模型，跳过单独的 ASR 步骤
public final class OmniTranscriber {
    public enum OmniError: Error, CustomStringConvertible {
        case noAPIKey
        case encodingFailed
        case noData
        case parseError
        case empty
        case http(status: Int, body: String?)

        public var description: String {
            switch self {
            case .noAPIKey: return "DASHSCOPE_API_KEY missing"
            case .encodingFailed: return "WAV encoding failed"
            case .noData: return "no response data"
            case .parseError: return "response parse error"
            case .empty: return "empty response"
            case .http(let status, _):
                return "HTTP \(status)"
            }
        }
    }

    public var debugLog: ((String) -> Void)?

    private let endpoint = URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")!
    private let defaultModel = "qwen3.5-omni-flash"
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func isConfigured() -> Bool {
        let key = VoicePolishConfig.shared.string(forKey: "dashscope_api_key", envKey: "DASHSCOPE_API_KEY")
        return !(key?.isEmpty ?? true)
    }

    public func process(samples: [Float], sampleRate: Int = 16000, completion: @escaping (Result<String, Error>) -> Void) {
        let config = VoicePolishConfig.shared
        guard let apiKey = config.string(forKey: "dashscope_api_key", envKey: "DASHSCOPE_API_KEY"),
              !apiKey.isEmpty else {
            debugLog?("OmniTranscriber not configured (missing dashscope_api_key)")
            completion(.failure(OmniError.noAPIKey))
            return
        }
        let model = config.string(forKey: "qwen_omni_model") ?? defaultModel

        guard let wavData = WAVEncoder.makeWAVData(from: samples, sampleRate: sampleRate) else {
            completion(.failure(OmniError.encodingFailed))
            return
        }
        let base64 = wavData.base64EncodedString()

        debugLog?("Omni processing started (model=\(model), samples=\(samples.count), wav=\(wavData.count) bytes)")
        let started = Date()

        // 個人詞庫注入：識別 + 整理一步完成，詞表跟著 system 提示走
        var systemPrompt = Self.systemPrompt
        if let sentence = PersonalVocabulary.asrContextSentence() {
            systemPrompt += """


            ## 使用者個人詞庫
            \(sentence)。聽到讀音相近的內容時，優先採用這些寫法，但不要憑空加入使用者沒說過的詞。
            """
        }
        // 風格畫像：識別+整理一步完成，讓成稿貼合使用者的說話習慣。
        if VoicePolishConfig.shared.bool(forKey: "style_profile_injection_enabled", defaultValue: false),
           let styleSection = StyleProfileStore.promptSection() {
            systemPrompt += "\n\n" + styleSection
        }

        let body: [String: Any] = [
            "model": model,
            "messages": [
                [
                    "role": "system",
                    "content": systemPrompt
                ],
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "input_audio",
                            "input_audio": [
                                "data": "data:;base64,\(base64)",
                                "format": "wav"
                            ]
                        ],
                        [
                            "type": "text",
                            "text": "請依上面的規則把這段錄音整理成好讀的文字。"
                        ]
                    ]
                ]
            ],
            "modalities": ["text"],
            "stream": false,
            "temperature": 0.5,
            "top_p": 0.8,
            "result_format": "message",
            "enable_thinking": false
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 90

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            completion(.failure(error))
            return
        }

        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)

            if let error = error {
                self.debugLog?("Omni request failed in \(elapsedMs)ms: \(error)")
                completion(.failure(error))
                return
            }
            guard let data = data else {
                self.debugLog?("Omni returned no data after \(elapsedMs)ms")
                completion(.failure(OmniError.noData))
                return
            }
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                let bodyString = String(data: data, encoding: .utf8)
                self.debugLog?("Omni API error: status=\(http.statusCode), responseBytes=\(data.count)")
                completion(.failure(OmniError.http(status: http.statusCode, body: bodyString)))
                return
            }

            do {
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = json["choices"] as? [[String: Any]],
                      let firstChoice = choices.first,
                      let message = firstChoice["message"] as? [String: Any] else {
                    self.debugLog?("Omni parse error after \(elapsedMs)ms, responseBytes=\(data.count)")
                    completion(.failure(OmniError.parseError))
                    return
                }

                // content 可能是 string 或者 多模态分段数组
                let text: String
                if let str = message["content"] as? String {
                    text = str
                } else if let arr = message["content"] as? [[String: Any]] {
                    text = arr.compactMap { $0["text"] as? String }.joined()
                } else {
                    text = ""
                }

                let usage = json["usage"] as? [String: Any]
                let inputTokens = usage?["prompt_tokens"] as? Int ?? 0
                let outputTokens = usage?["completion_tokens"] as? Int ?? 0
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

                if trimmed.isEmpty {
                    self.debugLog?("Omni returned empty text in \(elapsedMs)ms")
                    completion(.failure(OmniError.empty))
                    return
                }

                self.debugLog?("Omni done in \(elapsedMs)ms: chars=\(trimmed.count), tokens=\(inputTokens)/\(outputTokens)")
                completion(.success(trimmed))
            } catch {
                self.debugLog?("Omni JSON exception after \(elapsedMs)ms: \(error)")
                completion(.failure(error))
            }
        }.resume()
    }

    private static let systemPrompt = """
    你是語音轉文字的整理助手。使用者口述了一段話，你的任務是清除口誤和明顯冗餘，但**保持使用者原本的口語風格**。你不是在寫公文，是在幫使用者把口語整理成「他自己說的話」，只是更通順。

    ## 核心語言規則
    - 一律使用繁體中文（台灣習慣用詞與正體中文）輸出，除非使用者明確指定其他語言。

    ## 你要做的
    - 修正口誤：使用者自己糾正後，留下最終意圖（「週三…嗯不對…週四」→「週四」）
    - 刪冗餘：刪除重複的詞和無意義語氣詞（「嗯」「啊」「那個」「然後」）
    - 修標點：讓斷句更自然
    - 數字：中文數字轉阿拉伯數字（「兩到三次」→「2 到 3 次」），成語除外
    - 並列內容：使用者在明顯列舉時（「第一…第二…」），用編號列表

    ## 必須保留（絕對不要改！）
    - 口語助詞：「吧」「呢」「啊」「嘛」「喔」「喏」等表達語氣的字
    - 使用者的核心用詞：說「看看」不要改成「查看」，說「是不是」不要改成「是否」，說「全模型」不要改成「完整測試」
    - 使用者的句式：說「我打算…」就保留「我打算」，說「讓你…」就保留「讓你」

    ## 你不要做的
    - 不要總結、不要概括（你不是寫摘要）
    - 不要把口語換成書面語
    - 不要添加使用者沒說的內容，包括「好的」「了解」「收到」這種回應詞
    - 不要回答使用者的問題
    - 不要用粗體、標題等富文本格式

    ## 範例

    輸入：我們週三開會吧。嗯，不對，還是週四吧。
    輸出：我們週四開會吧。

    輸入：我打算後天去吃飯吧，還是大後天？
    輸出：我打算大後天去吃飯吧。

    輸入：那個，我感覺這個專案，就是它的進度有點慢，可能需要再加點人。
    輸出：我感覺這個專案的進度有點慢，可能需要再加點人。

    輸入：那我先測試一下，讓你在 iPhone 和 Mac 上各自跑一次那個對話的全模型，看看有三點吧。第一點是不是會主動分段。第二點是不是會把那個並列的一二三列表列出來。第三點就是整體的對話流暢度有沒有問題。
    輸出：那我先測試一下，讓你在 iPhone 和 Mac 上各自跑一次那個對話的全模型，看看有三點：
    1. 是不是會主動分段
    2. 是不是會把那個並列的一二三列表列出來
    3. 整體的對話流暢度有沒有問題
    """
}
