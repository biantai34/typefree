import Foundation

public final class CloudASRTranscriber {

    // MARK: - 服務商 & 識別版本
    public enum ASRProvider: String, CaseIterable {
        case groq      // Groq (Whisper)
        case openai    // OpenAI (Whisper)
        case gemini    // Google (Gemini)
        case volcano   // 火山引擎
        case bailian   // 阿里百煉（DashScope）
    }

    /// 可切換的識別版本，各有獨立免費額度：Groq / OpenAI / Gemini / 火山三檔 + 百煉一檔。
    public enum ASRVersion: String, CaseIterable {
        case groq       // Groq whisper-large-v3-turbo
        case openai     // OpenAI whisper-1
        case gemini     // Google Gemini (Gemini 3.8 Flash / 3.5 Flash)
        case turbo      // 火山極速版 1.0：同步 flash
        case standard   // 火山標準版 1.0：非同步 submit + 輪詢 query
        case v2         // 火山 2.0(seedasr)：非同步 submit + 輪詢 query
        case bailian    // 百煉 qwen3-asr-flash：同步 OpenAI 相容介面

        public var provider: ASRProvider {
            switch self {
            case .groq: return .groq
            case .openai: return .openai
            case .gemini: return .gemini
            case .turbo, .standard, .v2: return .volcano
            case .bailian: return .bailian
            }
        }

        /// 火山調用時填入 X-Api-Resource-Id 的值
        public var resourceID: String {
            switch self {
            case .turbo: return "volc.bigasr.auc_turbo"
            case .standard: return "volc.bigasr.auc"
            case .v2: return "volc.seedasr.auc"
            case .bailian, .groq, .openai, .gemini: return ""
            }
        }

        public var modelIdentifier: String {
            switch self {
            case .turbo, .standard, .v2: return resourceID
            case .bailian: return "qwen3-asr-flash"
            case .groq: return "whisper-large-v3-turbo"
            case .openai: return "whisper-1"
            case .gemini: return "gemini-3.8-flash"
            }
        }

        /// true = 同步一步出結果；false = 異步 submit/query
        public var isSync: Bool {
            switch self {
            case .groq, .openai, .gemini, .turbo, .bailian: return true
            case .standard, .v2: return false
            }
        }

        /// 給使用者看的名字
        public var displayName: String {
            switch self {
            case .groq: return "Groq Whisper"
            case .openai: return "OpenAI Whisper"
            case .gemini: return "Gemini 3.8 Flash"
            case .turbo: return "極速版"
            case .standard: return "標準版"
            case .v2: return "2.0"
            case .bailian: return "百煉"
            }
        }

        /// 建議切換順序
        public var nextForFallback: ASRVersion? {
            switch self {
            case .groq: return .openai
            case .openai: return .gemini
            case .gemini: return nil
            case .turbo: return .standard
            case .standard: return .v2
            case .v2: return .bailian
            case .bailian: return nil
            }
        }
    }

    private struct Credentials {
        enum AuthStyle {
            case apiKey(String)
            case appAccess(appID: String, accessToken: String)
        }
        let authStyle: AuthStyle
    }

    // MARK: - 錯誤分類
    public enum TranscriptionError: LocalizedError {
        case missingCredentials
        case invalidAudio
        case noData
        case parseError
        case network(underlying: Error)      // 網路層錯誤（斷網/超時）→ 不切版本
        case serverBusy(message: String)     // 伺服器臨時繁忙 → 原地可重試
        case serverFailed(message: String)   // 服務端業務失敗 / 額度耗盡 → 建議切版本
        case timeout                          // 輪詢超過時限
        case noSpeech                         // 無有效語音 → 當作「無內容」，不報錯

        public var errorDescription: String? {
            switch self {
            case .missingCredentials: return "未設定雲端語音識別憑證"
            case .invalidAudio: return "音訊編碼失敗"
            case .noData: return "雲端識別未返回資料"
            case .parseError: return "雲端識別返回無法解析"
            case .network(let e): return "網路錯誤：\(e.localizedDescription)"
            case .serverBusy(let m): return m
            case .serverFailed(let m): return m
            case .timeout: return "識別逾時"
            case .noSpeech: return "無內容"
            }
        }

        /// 疑似额度耗尽 / 业务失败 → 建议提示用户切换到下一个版本
        public var suggestsVersionSwitch: Bool {
            if case .serverFailed = self { return true }
            return false
        }

        /// 临时性错误 → 值得在当前版本原地重试一两次
        public var isRetriableInPlace: Bool {
            switch self {
            case .serverBusy, .timeout: return true
            default: return false
            }
        }
    }

    // MARK: - 端點
    private static let flashURL  = "https://openspeech.bytedance.com/api/v3/auc/bigmodel/recognize/flash"
    private static let submitURL = "https://openspeech.bytedance.com/api/v3/auc/bigmodel/submit"
    private static let queryURL  = "https://openspeech.bytedance.com/api/v3/auc/bigmodel/query"
    // 百煉(DashScope) OpenAI 相容 ASR：qwen3-asr-flash 同步一步出結果
    private static let bailianURL = "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"
    private static let bailianModel = ASRVersion.bailian.modelIdentifier
    // Groq Whisper API 端點
    private static let groqURL = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
    // OpenAI Whisper API 端點
    private static let openAIURL = URL(string: "https://api.openai.com/v1/audio/transcriptions")!

    private let config = VoicePolishConfig.shared
    public var debugLog: ((String) -> Void)?

    public init() {}

    // 熱詞詞表統一由 PersonalVocabulary 提供（內建 + 自訂 + 個人詞庫）

    public func isConfigured() -> Bool {
        isConfigured(version: currentVersion())
    }

    /// 當前版本對應服務商的憑證是否已配置。
    public func isConfigured(version: ASRVersion) -> Bool {
        switch version.provider {
        case .groq: return groqAPIKey() != nil
        case .openai: return openaiAPIKey() != nil
        case .gemini: return geminiAPIKey() != nil
        case .volcano: return volcanoCredentials() != nil
        case .bailian: return dashscopeAPIKey() != nil
        }
    }

    public func missingConfigurationHint() -> String {
        "請在「設定 → 模型」中設定 Groq、OpenAI、Gemini、火山或阿里百煉的 API Key"
    }

    // MARK: - 當前識別版本

    /// 使用者在設定裡選擇的識別版本，若有設定對應 key 則自動選取，預設 Groq（若有 Key）或極速版。
    public func currentVersion() -> ASRVersion {
        if let raw = config.string(forKey: "bigasr_version", envKey: "BIGASR_VERSION"),
           let v = ASRVersion(rawValue: raw) {
            return v
        }
        if groqAPIKey() != nil { return .groq }
        if openaiAPIKey() != nil { return .openai }
        if geminiAPIKey() != nil { return .gemini }
        return .turbo
    }

    /// 持久化版本选择（只在用户手动切换时写入）。
    public func persistVersion(_ version: ASRVersion) {
        config.save(value: version.rawValue, forKey: "bigasr_version")
    }

    /// 生成 API 的 corpus.context JSON 字符串（dialog_ctx 上下文格式）。
    /// 注意：不要改回 {"hotwords":[...]} 内联格式——那是流式接口的写法，
    /// 录音文件接口（极速版/标准版/2.0）会静默忽略它；dialog_ctx 三个版本实测均生效。
    private func hotWordsContextJSON() -> String? {
        guard let sentence = PersonalVocabulary.asrContextSentence() else { return nil }
        let contextObj: [String: Any] = [
            "context_type": "dialog_ctx",
            "context_data": [["text": sentence]]
        ]
        guard let contextData = try? JSONSerialization.data(withJSONObject: contextObj),
              let contextStr = String(data: contextData, encoding: .utf8) else {
            return nil
        }
        return contextStr
    }

    /// 热词请求字段。三个版本一致：内联热词、热词表、替换词表全部放在 request.corpus 下。
    /// （旧实现把 boosting_table_name 放在了 request 顶层，与火山文档不符、很可能不生效，此处修正。）
    private func hotWordRequestOptions() -> [String: Any] {
        var corpus: [String: Any] = [:]

        if let contextJSON = hotWordsContextJSON() {
            corpus["context"] = contextJSON
        }

        if let boostingTableName = config.string(forKey: "bigasr_boosting_table_name", envKey: "BIGASR_BOOSTING_TABLE_NAME"),
           !boostingTableName.isEmpty {
            corpus["boosting_table_name"] = boostingTableName
        } else if let boostingTableID = config.string(forKey: "bigasr_boosting_table_id", envKey: "BIGASR_BOOSTING_TABLE_ID"),
                  !boostingTableID.isEmpty {
            corpus["boosting_table_id"] = boostingTableID
        }

        if let correctTableName = config.string(forKey: "bigasr_correct_table_name", envKey: "BIGASR_CORRECT_TABLE_NAME"),
           !correctTableName.isEmpty {
            corpus["correct_table_name"] = correctTableName
        } else if let correctTableID = config.string(forKey: "bigasr_correct_table_id", envKey: "BIGASR_CORRECT_TABLE_ID"),
                  !correctTableID.isEmpty {
            corpus["correct_table_id"] = correctTableID
        }

        return corpus.isEmpty ? [:] : ["corpus": corpus]
    }

    // MARK: - 识别入口

    /// 用当前选择的版本识别。
    public func transcribe(samples: [Float], sampleRate: Int = 16000, completion: @escaping (Result<String, Error>) -> Void) {
        transcribe(samples: samples, sampleRate: sampleRate, version: currentVersion(), completion: completion)
    }

    /// 识别入口（自动分段）：≥10s 且存在语音停顿的录音，按停顿切段并行识别、按原顺序拼接，
    /// 明显缩短长录音等待；短录音、无停顿录音与 transcribe 完全一致。
    /// 并发上限默认 5，可用隐藏配置 chunk_asr_max_concurrent 调整；设为 1 即关闭分段（应急开关）。
    public func transcribeAuto(samples: [Float], sampleRate: Int = 16000, version: ASRVersion, completion: @escaping (Result<String, Error>) -> Void) {
        // 百炼限流是 100 RPM 且突发按秒级（约 1.6 次/秒）判定，一口气 5 段易被拒且其报错不走重试，
        // 故百炼降到 2 路并发；火山极速版官方默认 5 并发、标准版/2.0 为 20 QPS，用满 5 路没问题。
        let maxConcurrent = min(chunkMaxConcurrent(), version == .bailian ? 2 : Int.max)
        guard maxConcurrent > 1 else {
            transcribe(samples: samples, sampleRate: sampleRate, version: version, completion: completion)
            return
        }
        let plan = AudioChunker.planWithDiagnostics(samples: samples, sampleRate: sampleRate)
        if plan.duration >= AudioChunker.minSplitDuration {
            debugLog?("AudioChunker: \(plan.summary)")
        }
        let ranges = plan.ranges
        guard ranges.count > 1 else {
            transcribe(samples: samples, sampleRate: sampleRate, version: version, completion: completion)
            return
        }
        let chunkSeconds = ranges.map { String(format: "%.1f", Double($0.count) / Double(max(sampleRate, 1))) }
        debugLog?("Cloud ASR chunked: \(ranges.count) chunks (\(chunkSeconds.joined(separator: "s/"))s), maxConcurrent=\(maxConcurrent)")
        // 强持有 self：协调器是在它自己的串行队列上「异步」启动各分段的，此时调用方的方法
        // 往往已经返回。若这里用 weak，转写器可能已被释放 → guard 直接 return → chunkCompletion
        // 永不回调 → 整次识别永久挂起（历史记录「重试」卡死不出结果就是这个原因）。
        // 这不会造成循环引用：闭包由协调器持有，识别结束即释放。
        ChunkedASRCoordinator.run(samples: samples, ranges: ranges, maxConcurrent: maxConcurrent, transcribeChunk: { index, chunk, chunkCompletion in
            self.debugLog?("Cloud ASR chunk \(index + 1)/\(ranges.count) started")
            self.transcribe(samples: chunk, sampleRate: sampleRate, version: version, completion: chunkCompletion)
        }, completion: completion)
    }

    /// 分段识别并发上限（隐藏配置，默认 5；≤1 关闭分段）
    private func chunkMaxConcurrent() -> Int {
        if let raw = config.string(forKey: "chunk_asr_max_concurrent", envKey: "CHUNK_ASR_MAX_CONCURRENT"),
           let n = Int(raw) {
            return max(1, n)
        }
        return 5
    }

    /// 用指定版本识别。
    public func transcribe(samples: [Float], sampleRate: Int = 16000, version: ASRVersion, completion: @escaping (Result<String, Error>) -> Void) {
        // 优先压缩为 AAC/M4A 上传（体积约为 WAV 的 1/10，弱网更快、更不易超时），编码失败回退 WAV
        let audioData: Data
        let audioFormat: String
        if let m4aData = M4AEncoder.makeM4AData(from: samples, sampleRate: sampleRate), !m4aData.isEmpty {
            audioData = m4aData
            audioFormat = "m4a"
        } else if let wavData = WAVEncoder.makeWAVData(from: samples, sampleRate: sampleRate), !wavData.isEmpty {
            audioData = wavData
            audioFormat = "wav"
        } else {
            completion(.failure(TranscriptionError.invalidAudio))
            return
        }

        // 托管路由（owner 出 API 费）：自己的 Key 优先；其次有效会员 → /member/asr（服务器固定豆包 2.0）；
        // 再次免费试用 → /trial/asr（固定极速版 turbo，同步实时）。故意不跟随用户的「模型设置」——
        // 那设置是填了自己 Key 后才用的。已激活的老码（老买断/赠送）不走试用。
        let hostedRoute = HostedRoute.current(ownKeyConfigured: isConfigured(version: version))
        let usesTrialProxy = hostedRoute != .none
        // 自带 key（直连）识别成功后累计用量，等握手上报（仅数字、不含内容）；代理路径由服务器记账，故跳过避免重复。
        let originalCompletion = completion
        let completion: (Result<String, Error>) -> Void = usesTrialProxy ? originalCompletion : { result in
            if case .success(let text) = result, !text.isEmpty {
                TrialManager.shared.recordSelfKeyUsage(chars: text.count)
            }
            originalCompletion(result)
        }
        if usesTrialProxy {
            let body = makeRequestBody(audioData: audioData, format: audioFormat)
            if hostedRoute == .member {
                let seconds = Double(samples.count) / Double(max(sampleRate, 1))
                debugLog?("Cloud ASR: MEMBER via proxy audio=\(audioFormat)/\(audioData.count / 1024)KB")
                transcribeHosted(route: .member, jsonBody: ["body": body],
                                 timeout: Self.recognitionBudget(audioSeconds: seconds), completion: completion)
            } else {
                let trialVersion: ASRVersion = .turbo
                debugLog?("Cloud ASR: TRIAL via proxy, version=\(trialVersion.rawValue) audio=\(audioFormat)/\(audioData.count / 1024)KB")
                transcribeHosted(route: .trial, jsonBody: ["version": trialVersion.rawValue, "body": body],
                                 timeout: 30, completion: completion)
            }
            return
        }

        // 识别预算：基础 60s，按音频时长线性放宽，封顶 10 分钟。短录音仍 ~60s 不受影响；
        // 长录音（如 20-30 分钟）给服务器足够的处理/轮询时间，避免客户端提前超时（曾导致长录音无结果、还白录）。
        let audioSeconds = Double(samples.count) / Double(max(sampleRate, 1))
        let budget = Self.recognitionBudget(audioSeconds: audioSeconds)

        switch version.provider {
        case .groq:
            guard let apiKey = groqAPIKey() else {
                completion(.failure(TranscriptionError.missingCredentials))
                return
            }
            let model = config.string(forKey: "groq_asr_model") ?? "whisper-large-v3-turbo"
            debugLog?("Cloud ASR: version=groq provider=groq model=\(model) audio=\(audioFormat)/\(audioData.count / 1024)KB budget=\(Int(budget))s")
            transcribeWhisper(url: Self.groqURL, audioData: audioData, format: audioFormat, model: model, apiKey: apiKey, budgetSeconds: budget, completion: completion)
        case .openai:
            guard let apiKey = openaiAPIKey() else {
                completion(.failure(TranscriptionError.missingCredentials))
                return
            }
            let model = config.string(forKey: "openai_asr_model") ?? "whisper-1"
            debugLog?("Cloud ASR: version=openai provider=openai model=\(model) audio=\(audioFormat)/\(audioData.count / 1024)KB budget=\(Int(budget))s")
            transcribeWhisper(url: Self.openAIURL, audioData: audioData, format: audioFormat, model: model, apiKey: apiKey, budgetSeconds: budget, completion: completion)
        case .gemini:
            guard let apiKey = geminiAPIKey() else {
                completion(.failure(TranscriptionError.missingCredentials))
                return
            }
            let model = config.string(forKey: "gemini_asr_model") ?? "gemini-3.8-flash"
            debugLog?("Cloud ASR: version=gemini provider=gemini model=\(model) audio=\(audioFormat)/\(audioData.count / 1024)KB budget=\(Int(budget))s")
            transcribeGemini(audioData: audioData, format: audioFormat, apiKey: apiKey, budgetSeconds: budget, completion: completion)
        case .volcano:
            guard let credentials = volcanoCredentials() else {
                completion(.failure(TranscriptionError.missingCredentials))
                return
            }
            let body = makeRequestBody(audioData: audioData, format: audioFormat)
            let hotWordCount = PersonalVocabulary.currentWords().count
            debugLog?("Cloud ASR: version=\(version.rawValue) provider=volcano resource=\(version.resourceID) sync=\(version.isSync) hotwords=\(hotWordCount) audio=\(audioFormat)/\(audioData.count / 1024)KB budget=\(Int(budget))s")
            if version.isSync {
                transcribeSync(body: body, credentials: credentials, resourceID: version.resourceID, budgetSeconds: budget, completion: completion)
            } else {
                transcribeAsync(body: body, credentials: credentials, resourceID: version.resourceID, budgetSeconds: budget, completion: completion)
            }
        case .bailian:
            guard let apiKey = dashscopeAPIKey() else {
                completion(.failure(TranscriptionError.missingCredentials))
                return
            }
            // 百煉 qwen3-asr-flash 官方硬上限：音訊 ≤5 分鐘。
            if audioSeconds > 300 {
                let mins = Int((audioSeconds / 60).rounded())
                completion(.failure(TranscriptionError.serverFailed(message: "百煉識別最長支援 5 分鐘，這段約 \(mins) 分鐘過長。請在「模型」裡改用 Groq、OpenAI 或火山 2.0。")))
                return
            }
            debugLog?("Cloud ASR: version=\(version.rawValue) provider=bailian model=\(Self.bailianModel) audio=\(audioFormat)/\(audioData.count / 1024)KB budget=\(Int(budget))s")
            transcribeBailian(audioData: audioData, format: audioFormat, apiKey: apiKey, budgetSeconds: budget, completion: completion)
        }
    }

    /// 按音频时长给出识别等待预算：基础 60s + 时长×0.5，封顶 600s（10 分钟）。
    /// 短录音 ≈ 60s 不变；30 分钟（1800s）→ 封顶 600s，足够异步接口处理完。
    static func recognitionBudget(audioSeconds: Double) -> TimeInterval {
        return min(600, max(60, audioSeconds * 0.5 + 60))
    }

    // MARK: - 试用代理（POST /trial/asr，owner 出 API 费）

    /// 走服务器试用代理。HTTP 200 的响应体即火山原始响应（逐字透传），解析方式与 transcribeSync 完全一致；
    /// HTTP 非 200 是试用层错误，用服务器给的人话 error 文案。
    private func transcribeHosted(route: HostedRoute, jsonBody: [String: Any], timeout: TimeInterval,
                                  completion: @escaping (Result<String, Error>) -> Void) {
        TrialManager.shared.hostedPost(route: route, endpoint: "asr", jsonBody: jsonBody, timeout: timeout) { data, response, error in
            if let error = error {
                completion(.failure(TranscriptionError.network(underlying: error)))
                return
            }
            let status = response?.statusCode ?? 0
            if status == 200 {
                guard let data = data else {
                    completion(.failure(TranscriptionError.noData))
                    return
                }
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    completion(.failure(TranscriptionError.parseError))
                    return
                }
                if let text = Self.extractText(from: json) {
                    completion(.success(text))
                    return
                }
                // 200 但没拿到文本 → 火山状态码在 X-Api-Status-Code 头，按状态码分类
                completion(.failure(self.classifyServerError(status: Self.apiStatusCode(from: response), data: data)))
            } else {
                // 托管层错误（试用额度/会员隐藏限额等）：用服务器给的人话 error 文案
                let json = (try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: Any]
                let msg = (json?["error"] as? String) ?? (route == .member ? "會員辨識失敗（\(status)）" : "試用辨識失敗（\(status)）")
                completion(.failure(TranscriptionError.serverFailed(message: msg)))
            }
        }
    }

    // MARK: - 同步（极速版 flash）

    private func transcribeSync(body: [String: Any], credentials: Credentials, resourceID: String, budgetSeconds: TimeInterval, completion: @escaping (Result<String, Error>) -> Void) {
        guard var request = makeRequest(urlString: Self.flashURL, credentials: credentials, resourceID: resourceID, requestID: UUID().uuidString.lowercased()) else {
            completion(.failure(TranscriptionError.invalidAudio))
            return
        }
        request.timeoutInterval = budgetSeconds
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            completion(.failure(error))
            return
        }

        // 注意：不要用 [weak self]。测试连接等场景用临时实例，请求发出后实例即释放，
        // weak self 会变 nil 导致 completion 永不回调（界面卡在"测试中…"）。强持有 self 直到回调。
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(TranscriptionError.network(underlying: error)))
                return
            }
            guard let data = data else {
                completion(.failure(TranscriptionError.noData))
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(.failure(TranscriptionError.parseError))
                return
            }
            if let text = Self.extractText(from: json) {
                completion(.success(text))
                return
            }
            // 没拿到文本 → 按状态码分类失败
            completion(.failure(self.classifyServerError(status: Self.apiStatusCode(from: response), data: data)))
        }.resume()
    }

    // MARK: - 异步（标准版 / 2.0：submit + 轮询 query）

    private func transcribeAsync(body: [String: Any], credentials: Credentials, resourceID: String, budgetSeconds: TimeInterval, completion: @escaping (Result<String, Error>) -> Void) {
        let requestID = UUID().uuidString.lowercased()
        guard var submitReq = makeRequest(urlString: Self.submitURL, credentials: credentials, resourceID: resourceID, requestID: requestID) else {
            completion(.failure(TranscriptionError.invalidAudio))
            return
        }
        submitReq.timeoutInterval = budgetSeconds
        do {
            submitReq.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            completion(.failure(error))
            return
        }

        URLSession.shared.dataTask(with: submitReq) { _, response, error in
            if let error = error {
                completion(.failure(TranscriptionError.network(underlying: error)))
                return
            }
            let status = Self.apiStatusCode(from: response)
            // 提交成功(20000000)或已在排队/处理(2000000x) → 进入轮询；否则直接判失败
            if let status = status, status != 20000000, status != 20000001, status != 20000002 {
                completion(.failure(self.classifyServerError(status: status, data: nil)))
                return
            }
            self.pollQuery(requestID: requestID, credentials: credentials, resourceID: resourceID,
                           deadline: Date().addingTimeInterval(budgetSeconds), completion: completion)
        }.resume()
    }

    private func pollQuery(requestID: String, credentials: Credentials, resourceID: String,
                           deadline: Date, completion: @escaping (Result<String, Error>) -> Void) {
        if Date() > deadline {
            completion(.failure(TranscriptionError.timeout))
            return
        }
        guard var queryReq = makeRequest(urlString: Self.queryURL, credentials: credentials, resourceID: resourceID, requestID: requestID) else {
            completion(.failure(TranscriptionError.parseError))
            return
        }
        queryReq.httpBody = try? JSONSerialization.data(withJSONObject: [String: Any]())

        URLSession.shared.dataTask(with: queryReq) { data, response, error in
            if let error = error {
                completion(.failure(TranscriptionError.network(underlying: error)))
                return
            }
            let status = Self.apiStatusCode(from: response)
            switch status {
            case 20000000?:
                // 完成
                if let data = data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let text = Self.extractText(from: json) {
                    completion(.success(text))
                } else {
                    completion(.failure(TranscriptionError.serverFailed(message: "辨識完成但未返回文字")))
                }
            case 20000001?, 20000002?:
                // 处理中 / 排队中 → 0.3s 后再查
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.3) {
                    self.pollQuery(requestID: requestID, credentials: credentials, resourceID: resourceID,
                                   deadline: deadline, completion: completion)
                }
            default:
                completion(.failure(self.classifyServerError(status: status, data: data)))
            }
        }.resume()
    }

    // MARK: - 百炼（DashScope qwen3-asr-flash，同步一步）

    private func transcribeBailian(audioData: Data, format: String, apiKey: String, budgetSeconds: TimeInterval, completion: @escaping (Result<String, Error>) -> Void) {
        guard let url = URL(string: Self.bailianURL) else {
            completion(.failure(TranscriptionError.invalidAudio))
            return
        }
        let mimeType = format == "m4a" ? "audio/mp4" : "audio/wav"
        let dataURI = "data:\(mimeType);base64," + audioData.base64EncodedString()
        // qwen3-asr-flash 的热词机制：把词表放进 system 消息做上下文引导（官方定制化识别方式）
        let systemText = PersonalVocabulary.asrContextSentence() ?? ""
        let body: [String: Any] = [
            "model": Self.bailianModel,
            "messages": [
                ["role": "system", "content": [["type": "text", "text": systemText]]],
                ["role": "user", "content": [["type": "input_audio", "input_audio": ["data": dataURI]]]]
            ]
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = budgetSeconds
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            completion(.failure(error))
            return
        }
        // 同样不用 [weak self]，保证临时实例存活到回调。
        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error = error {
                completion(.failure(TranscriptionError.network(underlying: error)))
                return
            }
            guard let data = data else {
                completion(.failure(TranscriptionError.noData))
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(.failure(TranscriptionError.parseError))
                return
            }
            if let choices = json["choices"] as? [[String: Any]],
               let message = choices.first?["message"] as? [String: Any] {
                let content = (message["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !content.isEmpty {
                    completion(.success(content))
                } else {
                    // 正常返回但没文字 = 音频里没听出话（静音/太短），与火山 20000003 同等对待
                    completion(.failure(TranscriptionError.noSpeech))
                }
                return
            }
            // 失败：百炼把错误放在 error.message（额度/鉴权/限流等）→ 归为业务失败（可触发切下一个）。
            // 常见的 Key 错 / 欠费 / 限流由 AIPolisher.extractAPIErrorMessage 统一翻成中文，其余保留原话。
            let msg = AIPolisher.extractAPIErrorMessage(from: json) ?? "百煉辨識失敗"
            completion(.failure(TranscriptionError.serverFailed(message: msg)))
        }.resume()
    }

    // MARK: - 共享构造 / 解析

    private func makeRequest(urlString: String, credentials: Credentials, resourceID: String, requestID: String) -> URLRequest? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        switch credentials.authStyle {
        case .apiKey(let apiKey):
            request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        case .appAccess(let appID, let accessToken):
            request.setValue(appID, forHTTPHeaderField: "X-Api-App-Key")
            request.setValue(accessToken, forHTTPHeaderField: "X-Api-Access-Key")
        }
        request.setValue(resourceID, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(requestID, forHTTPHeaderField: "X-Api-Request-Id")
        request.setValue("-1", forHTTPHeaderField: "X-Api-Sequence")
        return request
    }

    private func makeRequestBody(audioData: Data, format: String) -> [String: Any] {
        var requestDict: [String: Any] = [
            "model_name": "bigmodel",
            "enable_itn": true,
            "enable_punc": true,
            "enable_ddc": true,
            "enable_speaker_info": false,
            "enable_channel_split": false,
            "show_utterances": true,
            "vad_segment": false,
            "sensitive_words_filter": ""
        ]
        for (key, value) in hotWordRequestOptions() {
            requestDict[key] = value
        }
        return [
            "user": ["uid": "豆包语音"],
            "audio": [
                "data": audioData.base64EncodedString(),
                "format": format,
                "language": ""
            ],
            "request": requestDict
        ]
    }

    /// 从识别返回里取文本：优先逐句拼接，回退整段 text。
    private static func extractText(from json: [String: Any]) -> String? {
        guard let result = json["result"] as? [String: Any] else { return nil }
        if let utterances = result["utterances"] as? [[String: Any]], !utterances.isEmpty {
            let sentences = utterances.compactMap { u in
                (u["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
            if !sentences.isEmpty {
                return sentences.joined(separator: "")
            }
        }
        if let text = (result["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return text
        }
        return nil
    }

    /// 火山的处理状态在响应头 X-Api-Status-Code，而非响应体。
    private static func apiStatusCode(from response: URLResponse?) -> Int? {
        guard let http = response as? HTTPURLResponse,
              let raw = http.value(forHTTPHeaderField: "X-Api-Status-Code"),
              let code = Int(raw) else {
            return nil
        }
        return code
    }

    private static func message(from data: Data?) -> String? {
        guard let data = data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return (json["message"] as? String) ?? (json["msg"] as? String) ?? (json["error"] as? String)
    }

    // MARK: - Whisper（Groq / OpenAI 相容介面）

    private func transcribeWhisper(url: URL, audioData: Data, format: String, model: String, apiKey: String, budgetSeconds: TimeInterval, completion: @escaping (Result<String, Error>) -> Void) {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = budgetSeconds
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func appendFormField(named name: String, value: String) {
            guard let header = "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8),
                  let val = value.data(using: .utf8),
                  let footer = "\r\n".data(using: .utf8) else { return }
            body.append(header)
            body.append(val)
            body.append(footer)
        }

        appendFormField(named: "model", value: model)
        appendFormField(named: "response_format", value: "json")
        if let context = PersonalVocabulary.asrContextSentence(), !context.isEmpty {
            appendFormField(named: "prompt", value: context)
        }

        let filename = "audio.\(format)"
        let mimeType = (format == "m4a") ? "audio/m4a" : "audio/wav"
        if let fileHeader = "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: \(mimeType)\r\n\r\n".data(using: .utf8),
           let fileFooter = "\r\n--\(boundary)--\r\n".data(using: .utf8) {
            body.append(fileHeader)
            body.append(audioData)
            body.append(fileFooter)
        }
        request.httpBody = body

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(TranscriptionError.network(underlying: error)))
                return
            }
            guard let data = data else {
                completion(.failure(TranscriptionError.noData))
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(.failure(TranscriptionError.parseError))
                return
            }
            if let text = json["text"] as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    completion(.success(trimmed))
                } else {
                    completion(.failure(TranscriptionError.noSpeech))
                }
                return
            }
            let msg = AIPolisher.extractAPIErrorMessage(from: json) ?? "Whisper 語音轉寫失敗"
            completion(.failure(TranscriptionError.serverFailed(message: msg)))
        }.resume()
    }

    // MARK: - Gemini（Google 多模態音訊轉寫）

    private func transcribeGemini(audioData: Data, format: String, apiKey: String, budgetSeconds: TimeInterval, completion: @escaping (Result<String, Error>) -> Void) {
        let preferredModel = config.string(forKey: "gemini_asr_model") ?? "gemini-3.8-flash"
        callGeminiASR(model: preferredModel, audioData: audioData, format: format, apiKey: apiKey, budgetSeconds: budgetSeconds) { [weak self] result in
            switch result {
            case .success(let text):
                completion(.success(text))
            case .failure(let error):
                // 若首選模型遭遇失敗（例如 3.8 音訊在部分地區回傳 503 暫時不可用），自動備援至 gemini-3.5-flash
                if preferredModel != "gemini-3.5-flash" {
                    self?.debugLog?("Gemini ASR \(preferredModel) failed, falling back to gemini-3.5-flash: \(error.localizedDescription)")
                    self?.callGeminiASR(model: "gemini-3.5-flash", audioData: audioData, format: format, apiKey: apiKey, budgetSeconds: budgetSeconds, completion: completion)
                } else {
                    completion(.failure(error))
                }
            }
        }
    }

    private func callGeminiASR(model: String, audioData: Data, format: String, apiKey: String, budgetSeconds: TimeInterval, completion: @escaping (Result<String, Error>) -> Void) {
        let endpoint = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)"
        guard let url = URL(string: endpoint) else {
            completion(.failure(TranscriptionError.invalidAudio))
            return
        }

        let mimeType = (format == "m4a") ? "audio/mp4" : "audio/wav"
        let base64 = audioData.base64EncodedString()
        var prompt = "請將這段語音轉寫為繁體中文文字。只需輸出轉寫的逐字文字內容，不要包含任何解釋、開場白或多餘標記。如果音訊為靜音或無人聲，請直接返回空字串。"
        if let context = PersonalVocabulary.asrContextSentence(), !context.isEmpty {
            prompt += " 專有名詞參考：\(context)。"
        }

        let body: [String: Any] = [
            "contents": [
                [
                    "role": "user",
                    "parts": [
                        ["text": prompt],
                        ["inlineData": ["mimeType": mimeType, "data": base64]]
                    ]
                ]
            ],
            "generationConfig": [
                "temperature": 0.0
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = budgetSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            completion(.failure(error))
            return
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(TranscriptionError.network(underlying: error)))
                return
            }
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                let msg = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                    .flatMap { AIPolisher.extractAPIErrorMessage(from: $0) }
                    ?? "HTTP \(http.statusCode)"
                completion(.failure(TranscriptionError.serverFailed(message: "Gemini \(model) (\(msg))")))
                return
            }
            guard let data = data else {
                completion(.failure(TranscriptionError.noData))
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(.failure(TranscriptionError.parseError))
                return
            }
            if let candidates = json["candidates"] as? [[String: Any]],
               let content = candidates.first?["content"] as? [String: Any],
               let parts = content["parts"] as? [[String: Any]] {
                let text = parts.compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    completion(.success(text))
                } else {
                    completion(.failure(TranscriptionError.noSpeech))
                }
                return
            }
            let msg = AIPolisher.extractAPIErrorMessage(from: json) ?? "Gemini 語音辨識失敗"
            completion(.failure(TranscriptionError.serverFailed(message: msg)))
        }.resume()
    }

    /// 把服務端失敗分成「臨時繁忙（原地重試）」和「業務失敗（建議切版本）」。
    private func classifyServerError(status: Int?, data: Data?) -> TranscriptionError {
        let message = Self.message(from: data) ?? "雲端識別失敗"
        guard let status = status else {
            return .serverFailed(message: message)
        }
        if status == 55000031 {   // 伺服器繁忙：服務超載，臨時性
            return .serverBusy(message: "\(message)（伺服器繁忙）")
        }
        if status == 20000003 {   // 音訊無有效語音（靜音 / 太短）→ 當作「無內容」，不報紅框
            return .noSpeech
        }
        if status == 45000030 {   // HTTP 403：帳號未開通該識別版本
            return .serverFailed(message: "火山帳號未開通此識別版本，請到控制台開通並領取免費額度（45000030）")
        }
        if status == 45000010 {   // HTTP 401：API Key 不對
            return .serverFailed(message: "火山 API Key 無效，請檢查是否複製完整（45000010）")
        }
        return .serverFailed(message: "\(message)（狀態碼 \(status)）")
    }

    // MARK: - 憑證讀取

    public func groqAPIKey() -> String? {
        if let key = config.string(forKey: "groq_api_key", envKey: "GROQ_API_KEY"), !key.isEmpty { return key }
        return nil
    }

    public func openaiAPIKey() -> String? {
        if let key = config.string(forKey: "openai_api_key", envKey: "OPENAI_API_KEY"), !key.isEmpty { return key }
        return nil
    }

    public func geminiAPIKey() -> String? {
        if let key = config.string(forKey: "gemini_api_key", envKey: "GEMINI_API_KEY"), !key.isEmpty { return key }
        return nil
    }

    /// 百煉憑證：DashScope API Key（與語音優化的通義千問共用同一個 key）。
    private func dashscopeAPIKey() -> String? {
        if let key = config.string(forKey: "dashscope_api_key", envKey: "DASHSCOPE_API_KEY"),
           !key.isEmpty {
            return key
        }
        return nil
    }

    /// 火山憑證：新版單 API Key 優先，相容舊版 App ID + Access Token。
    private func volcanoCredentials() -> Credentials? {
        if let apiKey = config.string(forKey: "bigasr_api_key", envKey: "BIGASR_API_KEY"),
           !apiKey.isEmpty {
            return Credentials(authStyle: .apiKey(apiKey))
        }
        if let appID = config.string(forKey: "bigasr_app_id", envKey: "BIGASR_APP_ID"),
           let accessToken = config.string(forKey: "bigasr_access_token", envKey: "BIGASR_ACCESS_TOKEN"),
           !appID.isEmpty,
           !accessToken.isEmpty {
            return Credentials(authStyle: .appAccess(appID: appID, accessToken: accessToken))
        }
        return nil
    }
}
