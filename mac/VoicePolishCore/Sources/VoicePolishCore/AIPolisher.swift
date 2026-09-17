import Foundation

public class AIPolisher {
    public enum HistoryRetention: String, CaseIterable {
        case forever
        case oneMonth
        case oneWeek
        case oneDay
        case off

        public static let configKey = "history_retention"
        public static let defaultValue: HistoryRetention = .forever

        public var title: String {
            switch self {
            case .forever: return "保存全部資料"
            case .oneMonth: return "保存一個月"
            case .oneWeek: return "保存一週"
            case .oneDay: return "保存 24 小時"
            case .off: return "不保存資料"
            }
        }

        public var detail: String {
            switch self {
            case .forever: return "不自動刪除歷史記錄"
            case .oneMonth: return "自動刪除 30 天前的記錄"
            case .oneWeek: return "自動刪除 7 天前的記錄"
            case .oneDay: return "自動刪除 24 小時前的記錄"
            case .off: return "錄音結束後不保留任何本機歷史"
            }
        }

        fileprivate func cutoffDate(now: Date) -> Date? {
            switch self {
            case .forever:
                return nil
            case .oneMonth:
                return Calendar.current.date(byAdding: .day, value: -30, to: now)
            case .oneWeek:
                return Calendar.current.date(byAdding: .day, value: -7, to: now)
            case .oneDay:
                return Calendar.current.date(byAdding: .hour, value: -24, to: now)
            case .off:
                return .distantFuture  // 任何记录都视为过期 → 立即清除（含切到本项前的存量）
            }
        }
    }

    public struct TermCorrection {
        public let target: String
        public let variants: [String]
    }

    public struct PolishLog: Codable {
        public let time: String
        public let app: String
        public let asr: String
        public let output: String
        public let duration_ms: Int
        public let input_tokens: Int
        public let output_tokens: Int
        /// 新增：每条记录的稳定唯一标识。旧数据缺失则为 nil（用 stableIdentity 兜底）。
        public let id: String?
        /// 新增：关联音频文件名（相对 audio/ 目录，如 "<id>.m4a"）。无音频则 nil。
        public let audioFile: String?
        /// 记录类型：nil = 普通语音输入；"ask" = 长按问 AI（asr 存问题、output 存回答）
        public let kind: String?
        /// 问 AI 的话题 id：同一次对话里的多轮共用，历史页按它合并成一张卡
        public let thread: String?

        public init(time: String, app: String, asr: String, output: String, duration_ms: Int, input_tokens: Int, output_tokens: Int, id: String? = nil, audioFile: String? = nil, kind: String? = nil, thread: String? = nil) {
            self.time = time
            self.app = app
            self.asr = asr
            self.output = output
            self.duration_ms = duration_ms
            self.input_tokens = input_tokens
            self.output_tokens = output_tokens
            self.id = id
            self.audioFile = audioFile
            self.kind = kind
            self.thread = thread
        }

        public var isAsk: Bool { kind == "ask" }

        /// UI 用的稳定标识：新数据用 id；旧数据用关键字段哈希兜底（time 秒级精度不够）。
        public func stableIdentity(lineIndex: Int) -> String {
            if let id = id, !id.isEmpty { return id }
            return "legacy-\(lineIndex)-\(time)-\(asr.hashValue)-\(output.hashValue)"
        }
    }

    private static let defaultDoubaoPolishModel = "doubao-seed-2-0-pro-260215"
    private let apiURL = URL(string: "https://ark.cn-beijing.volces.com/api/v3/chat/completions")!
    private let model = AIPolisher.defaultDoubaoPolishModel
    public var debugLog: ((String) -> Void)?
    public var polishLogAppNameProvider: (() -> String)?

    public init() {}

    public struct PolishSelection {
        public let provider: String
        public let model: String?

        public init(provider: String, model: String?) {
            self.provider = provider
            self.model = model
        }
    }

    public static func currentPolishSelection() -> PolishSelection {
        let config = VoicePolishConfig.shared
        let provider = config.string(forKey: "polish_provider") ?? "gemini"
        if isPolishDisabled(provider: provider) {
            return PolishSelection(provider: "none", model: nil)
        }
        switch provider {
        case "gemini":
            let saved = config.string(forKey: "gemini_polish_model")
            return PolishSelection(provider: "gemini", model: (saved?.isEmpty == false) ? saved! : "gemini-3.8-flash")
        case "openai":
            let saved = config.string(forKey: "openai_polish_model")
            return PolishSelection(provider: "openai", model: (saved?.isEmpty == false) ? saved! : "gpt-4o-mini")
        case "groq":
            let saved = config.string(forKey: "groq_polish_model")
            return PolishSelection(provider: "groq", model: (saved?.isEmpty == false) ? saved! : "llama-3.3-70b-versatile")
        case "qwen":
            let saved = config.string(forKey: "qwen_polish_model")
            return PolishSelection(provider: "qwen", model: (saved?.isEmpty == false) ? saved! : "qwen3.6-flash")
        case "zhipu":
            return PolishSelection(provider: "zhipu", model: config.string(forKey: "zhipu_polish_model") ?? "glm-4.7-flash")
        default:
            let saved = config.string(forKey: "doubao_polish_model")
            return PolishSelection(provider: "doubao", model: (saved?.isEmpty == false) ? saved! : defaultDoubaoPolishModel)
        }
    }

    // MARK: - 术语纠正

    public func applyConfiguredTermCorrections(to text: String) -> String {
        Self.applyTermCorrections(configuredTermCorrections(), to: text)
    }

    /// 按词库把误写换成正写（2026-09-11 重写，旧版逐条整段替换会改坏正确的字）：
    /// - 已经是正写的地方不动：误写恰好是正写的一部分时（误写 APIK、正写 APIKey），原文里的 APIKey 不能变成 APIKeyey；
    /// - 英文/数字的误写要整词命中，前后不能紧挨英文字母或数字（SQL 不改 PostgreSQL 的尾巴）；中文没有词边界，照旧；
    /// - 单遍替换：所有命中都在原文上找，长的误写优先、互不重叠，换进去的正写不会再被别的规则改一遍。
    static func applyTermCorrections(_ corrections: [TermCorrection], to text: String) -> String {
        let pairs = corrections
            .flatMap { correction in correction.variants.map { (variant: $0, target: correction.target) } }
            .filter { !$0.variant.isEmpty && $0.variant != $0.target }
            .sorted { $0.variant.count > $1.variant.count }
        guard !pairs.isEmpty, !text.isEmpty else { return text }

        let source = text as NSString
        var accepted: [(range: NSRange, target: String)] = []
        for pair in pairs {
            // 只差大小写的规则（chatgpt → ChatGPT）只改写法不对的地方；其余规则避开原文里已是正写的位置
            let caseOnly = pair.variant.caseInsensitiveCompare(pair.target) == .orderedSame
            let correctSpots = caseOnly ? [] : occurrences(of: pair.target, in: source)
            for range in occurrences(of: pair.variant, in: source) {
                guard isWholeLatinWord(range, variant: pair.variant, in: source) else { continue }
                if caseOnly, source.substring(with: range) == pair.target { continue }
                if correctSpots.contains(where: { NSIntersectionRange($0, range).length > 0 }) { continue }
                if accepted.contains(where: { NSIntersectionRange($0.range, range).length > 0 }) { continue }
                accepted.append((range, pair.target))
            }
        }
        guard !accepted.isEmpty else { return text }

        let result = NSMutableString(string: text)
        for match in accepted.sorted(by: { $0.range.location > $1.range.location }) {
            result.replaceCharacters(in: match.range, with: match.target)
        }
        return result as String
    }

    /// 不分大小写地找出 needle 在 text 里的所有（不重叠）位置
    private static func occurrences(of needle: String, in text: NSString) -> [NSRange] {
        guard !needle.isEmpty else { return [] }
        var ranges: [NSRange] = []
        var location = 0
        while location < text.length {
            let found = text.range(of: needle, options: .caseInsensitive,
                                   range: NSRange(location: location, length: text.length - location))
            guard found.location != NSNotFound, found.length > 0 else { break }
            ranges.append(found)
            location = found.location + found.length
        }
        return ranges
    }

    /// 以英文字母/数字开头（结尾）的误写，前（后）一个字符不能也是英文字母/数字，否则是命中了长单词的一部分
    private static func isWholeLatinWord(_ range: NSRange, variant: String, in text: NSString) -> Bool {
        func isLatinAlphanumeric(_ c: unichar) -> Bool {
            (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
        }
        let v = variant as NSString
        if isLatinAlphanumeric(v.character(at: 0)), range.location > 0,
           isLatinAlphanumeric(text.character(at: range.location - 1)) {
            return false
        }
        let end = range.location + range.length
        if isLatinAlphanumeric(v.character(at: v.length - 1)), end < text.length,
           isLatinAlphanumeric(text.character(at: end)) {
            return false
        }
        return true
    }

    public func meaningfulCharacterCount(in text: String) -> Int {
        text.unicodeScalars.reduce(0) { partialResult, scalar in
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { return partialResult }
            if CharacterSet.punctuationCharacters.contains(scalar) { return partialResult }
            if CharacterSet.symbols.contains(scalar) { return partialResult }
            return partialResult + 1
        }
    }

    private func configuredTermCorrections() -> [TermCorrection] {
        guard let data = try? Data(contentsOf: VoicePolishConfig.shared.configFileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["term_corrections"] as? [[String: Any]] else {
            return []
        }

        return items.compactMap { item in
            guard let target = (item["target"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !target.isEmpty else {
                return nil
            }

            let variants = item["variants"] as? [String] ?? []
            let cleanedVariants = variants
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0 != target }

            return TermCorrection(target: target, variants: cleanedVariants)
        }
    }

    private func configuredPersonalVocabulary() -> [String] {
        guard let data = try? Data(contentsOf: VoicePolishConfig.shared.configFileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        var words: [String] = []
        if let entries = json["term_corrections"] as? [[String: Any]] {
            words.append(contentsOf: entries.compactMap { entry in
                if let enabled = entry["enabled"] as? Bool, !enabled {
                    return nil
                }
                guard let target = (entry["target"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !target.isEmpty else {
                    return nil
                }
                return target
            })
        }

        if let hotWords = json["hot_words"] as? [String] {
            words.append(contentsOf: hotWords.compactMap { rawWord in
                let word = rawWord
                    .split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
                    .first
                    .map(String.init)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return word?.isEmpty == false ? word : nil
            })
        }

        var seen = Set<String>()
        return words.filter { word in
            let key = word.lowercased()
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }

    private func personalVocabularyPrompt() -> String {
        let words = configuredPersonalVocabulary()
        guard !words.isEmpty else { return "" }

        let limitedWords = words.prefix(80).joined(separator: "、")
        return """

        ## 使用者個人詞庫
        以下是使用者常說的人名、產品名、專案名或專有表達。整理文字時要優先保留這些準確寫法；當語音轉寫裡出現讀音相近、大小寫不同或空格不同的表達時，可以修正為詞庫中的寫法，但不要憑空加入使用者沒有表達過的詞：\(limitedWords)
        """
    }

    /// 完整潤色 system prompt：基礎規則 + 個人詞庫 + 風格畫像（都是有內容才附加）。
    private func composedPolishSystemPrompt(outputLanguage: OutputLanguage? = nil) -> String {
        var prompt = cloudASRPolishPrompt
        if let outputLanguage { prompt += Self.outputLanguageSystemSection(for: outputLanguage) }
        if VoicePolishConfig.shared.bool(forKey: "polish_vocab_injection_enabled", defaultValue: false) {
            prompt += personalVocabularyPrompt()
        }
        if VoicePolishConfig.shared.bool(forKey: "style_profile_injection_enabled", defaultValue: false),
           let styleSection = StyleProfileStore.promptSection(forAppName: polishLogAppNameProvider?()) {
            prompt += "\n\n" + styleSection
        }
        return prompt
    }

    // MARK: - 雲端 ASR 後潤色

    private let cloudASRPolishPrompt = """
    你是一個語音轉文字的整理助手。使用者透過語音輸入了一段話，你要把它整理成好讀、通順的文字。

    ## 你的角色
    想像你是使用者的表達優化師，使用者口述了一段想法，你幫他整理成使用者看到結果時覺得「這就是我想說的，只是整理得更清楚、便於閱讀和理解」。

    ## 核心語言規則（極其重要）
    - 一律使用繁體中文（台灣習慣用詞與正體中文）整理輸出，除非使用者明確要求其他語言。
    - 絕不要添加使用者沒說過的內容，包括問候語、總結句、過渡句或小標題。

    ## 可以做的事
    - 分段：根據語意、語境分段，避免大段文字堆積，讓閱讀體驗更好。
    - 標點：修正標點符號，讓斷句更自然。適當使用冒號、分號來連接關聯內容。
    - 列表：當使用者表達的語意包含並列內容，或使用者說「第一、第二、第三」「一個是、另一個是、最後」，或明顯是在口述步驟/清單/多個獨立條目時，將其中適合並列的項目以編號列表顯示。
    - 去除口語贅詞：刪掉重複的詞、無意義的語氣詞（「就是」、「然後」、「嗯」、「那個」等）。
    - 理順斷句：口語中斷裂或不通順的句子，可以根據語意適當輕微調整語序使其通順。
    - 數字：口語中的中文數字轉為阿拉伯數字（「兩到三次」→「2 到 3 次」，「大概五百塊」→「大概 500 塊」），但成語、固定搭配除外（「一模一樣」、「三心二意」不轉）。
    - 明顯重複的詞組、繞口表達要合併整理，但絕不改變使用者原意。
    - 如果一句話本身已經通順，可以少改；但如果存在明顯重複、語序繞、主語不清，要主動整理到自然可讀。

    ## 不能做的事
    - 不要回答或回應使用者說的內容——你不是對話助手，你是使用者的表達轉寫整理工具。即使使用者說的是一個問題，也不要給出答案或建議。
    - 同義詞不隨意替換：保留使用者原本的說話風格。
    - 不要把口語改成生硬的公文語。
    - 不要使用粗體、標題等富文本格式。
    - 不要隨意更換使用者的用詞，除非邏輯明顯不通。
    - 不要翻譯使用者輸入的語言種類（除非有指定目標語言）。

    ## 輸出格式
    純文字，適當分段。並列內容用編號列表。不要粗體、不要加標題。
    """

    /// 使用者是否選擇了「不優化」（polish_provider == "none"）。
    public static func isPolishDisabled(provider: String?) -> Bool {
        provider?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "none"
    }

    public func isPolishEnabled() -> Bool {
        !Self.isPolishDisabled(provider: VoicePolishConfig.shared.string(forKey: "polish_provider"))
    }

    /// 使用者要求本次用某種語言輸出時附在待整理文字後面的標記；system prompt 裡的「目標語言」一節解釋它。
    static func outputRequestMarker(for language: OutputLanguage) -> String { "【本次要求：用\(language.name)輸出】" }

    static func outputLanguageSystemSection(for language: OutputLanguage) -> String {
        """


        ## 目標語言
        如果待整理文本後面帶有\(outputRequestMarker(for: language))，說明使用者要求這段話用\(language.name)輸出：先按上面的規則整理，再把整理結果翻譯成自然、道地的\(language.name)，只輸出\(language.name)譯文；人名、產品名、專有名詞保留原樣；不要輸出其他語言，不要加任何說明或翻譯標記。如果整理後的文字本來就是\(language.name)，直接輸出整理結果。此時「不要翻譯使用者輸入的語言種類」這條不適用。
        """
    }

    static func makeCloudASRPolishUserPrompt(for text: String, outputLanguage: OutputLanguage? = nil) -> String {
        if let outputLanguage {
            return """
            待整理文本：
            \(text)

            \(outputRequestMarker(for: outputLanguage))
            """
        }
        if shouldUseLanguagePreservingPrompt(for: text) {
            return """
            Keep the original language. Do not translate. Preserve Chinese and English as they appear. Polish this speech transcript only:
            \(text)
            """
        }

        return """
        待整理文本：
        \(text)
        """
    }

    private static func shouldUseLanguagePreservingPrompt(for text: String) -> Bool {
        var latinLetters = 0
        var cjkCharacters = 0
        var englishWords = 0
        var currentEnglishWordLength = 0

        func finishEnglishWord() {
            if currentEnglishWordLength >= 2 {
                englishWords += 1
            }
            currentEnglishWordLength = 0
        }

        for scalar in text.unicodeScalars {
            if isASCIILetter(scalar) {
                latinLetters += 1
                currentEnglishWordLength += 1
            } else {
                finishEnglishWord()
                if isCJKCharacter(scalar) {
                    cjkCharacters += 1
                }
            }
        }
        finishEnglishWord()

        let hasEnglishSentence = englishWords >= 3 || latinLetters >= max(8, cjkCharacters)
        let hasMixedChineseEnglish = cjkCharacters > 0 && englishWords >= 2
        return hasEnglishSentence || hasMixedChineseEnglish
    }

    private static func isASCIILetter(_ scalar: UnicodeScalar) -> Bool {
        (65...90).contains(Int(scalar.value)) || (97...122).contains(Int(scalar.value))
    }

    private static func isCJKCharacter(_ scalar: UnicodeScalar) -> Bool {
        (0x4E00...0x9FFF).contains(Int(scalar.value))
    }

    private func polishProvider() -> (name: String, url: URL, model: String, apiKey: String)? {
        let config = VoicePolishConfig.shared
        let provider = config.string(forKey: "polish_provider") ?? "gemini"

        switch provider {
        case "gemini":
            guard let key = config.string(forKey: "gemini_api_key", envKey: "GEMINI_API_KEY"),
                  !key.isEmpty else { return nil }
            let model = config.string(forKey: "gemini_polish_model") ?? "gemini-3.8-flash"
            let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")!
            return ("gemini", url, model, key)
        case "openai":
            guard let key = config.string(forKey: "openai_api_key", envKey: "OPENAI_API_KEY"),
                  !key.isEmpty else { return nil }
            let model = config.string(forKey: "openai_polish_model") ?? "gpt-4o-mini"
            let url = URL(string: "https://api.openai.com/v1/chat/completions")!
            return ("openai", url, model, key)
        case "groq":
            guard let key = config.string(forKey: "groq_api_key", envKey: "GROQ_API_KEY"),
                  !key.isEmpty else { return nil }
            let model = config.string(forKey: "groq_polish_model") ?? "llama-3.3-70b-versatile"
            let url = URL(string: "https://api.groq.com/openai/v1/chat/completions")!
            return ("groq", url, model, key)
        case "qwen":
            guard let key = config.string(forKey: "dashscope_api_key", envKey: "DASHSCOPE_API_KEY"),
                  !key.isEmpty else { return nil }
            let saved = config.string(forKey: "qwen_polish_model")
            let model = (saved?.isEmpty == false) ? saved! : PolishModelRouter.autoValue
            let url = URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")!
            return ("qwen", url, model, key)
        case "zhipu":
            guard let key = config.string(forKey: "zhipu_api_key", envKey: "ZHIPU_API_KEY"),
                  !key.isEmpty else { return nil }
            let model = config.string(forKey: "zhipu_polish_model") ?? "glm-4.7-flash"
            let url = URL(string: "https://open.bigmodel.cn/api/paas/v4/chat/completions")!
            return ("zhipu", url, model, key)
        default:
            guard let key = getAPIKey() else { return nil }
            let saved = config.string(forKey: "doubao_polish_model")
            let doubaoModel = (saved?.isEmpty == false) ? saved! : model
            return ("doubao", apiURL, doubaoModel, key)
        }
    }

    /// outputLanguage：使用者用語音口令要求的目標語言（nil = 照常保留原語言）
    public func polishCloudASROutput(text: String, outputLanguage: OutputLanguage? = nil, completion: @escaping (Result<String, Error>) -> Void) {
        // 會員選了「優先走會員服務」：填了自己的 Key 也走會員通道（使用者沒選「不優化」時）
        if HostedRoute.current(ownKeyConfigured: polishProvider() != nil) == .member,
           !Self.isPolishDisabled(provider: VoicePolishConfig.shared.string(forKey: "polish_provider")) {
            polishHosted(route: .member, text: text, outputLanguage: outputLanguage, completion: completion)
            return
        }
        guard let provider = polishProvider() else {
            let providerSetting = VoicePolishConfig.shared.string(forKey: "polish_provider")
            let hostedRoute = HostedRoute.current(ownKeyConfigured: false)
            if !Self.isPolishDisabled(provider: providerSetting) && hostedRoute != .none {
                polishHosted(route: hostedRoute, text: text, outputLanguage: outputLanguage, completion: completion)
                return
            }
            completion(.failure(PolishError.noAPIKey))
            return
        }

        debugLog?("Cloud ASR polish provider=\(provider.name) model=\(provider.model)")

        let systemPrompt = composedPolishSystemPrompt(outputLanguage: outputLanguage)
        let userPrompt = Self.makeCloudASRPolishUserPrompt(for: text, outputLanguage: outputLanguage)

        func makeBody(_ model: String) -> [String: Any] {
            var body: [String: Any] = [
                "model": model,
                "messages": [
                    ["role": "system", "content": systemPrompt],
                    ["role": "user", "content": userPrompt]
                ]
            ]
            if provider.name == "qwen" {
                body["top_p"] = 0.8
                body["temperature"] = 0.7
                body["result_format"] = "message"
                body["enable_thinking"] = false
            } else if provider.name == "gemini" || provider.name == "openai" || provider.name == "groq" {
                body["temperature"] = 0.3
                body["max_tokens"] = 2500
            } else if provider.name == "zhipu" {
                body["temperature"] = 0.1
                body["max_tokens"] = 2000
                body["thinking"] = ["type": "disabled"]
            } else {  // doubao
                body["temperature"] = 0.1
                body["max_tokens"] = 2000
                body["thinking"] = ["type": "disabled"]
            }
            return body
        }

        let finish: (Result<(String, Int, Int), Error>) -> Void = { result in
            switch result {
            case .success(let (content, _, _)):
                // 自带 key（直连）润色成功 → 累计用量，等握手上报（仅数字、不含内容）；代理润色由服务器记账。
                if !content.isEmpty { TrialManager.shared.recordSelfKeyUsage(chars: content.count) }
                completion(.success(content))
            case .failure(let error):
                completion(.failure(error))
            }
        }

        if provider.name == "qwen" {
            // 自动选择 → 对应候选队列（质量优先/速度优先）；手动选择 → 单模型（403 也会被标记，供设置页提示）。
            let candidates = PolishModelRouter.isAuto(provider.model)
                ? PolishModelRouter.candidates(for: provider.model)
                : [provider.model]
            attemptQwenPolish(candidates: candidates, url: provider.url, apiKey: provider.apiKey,
                              makeBody: makeBody, completion: finish)
        } else {
            callChatCompletionsWithTokens(url: provider.url, apiKey: provider.apiKey,
                                          body: makeBody(provider.model), completion: finish)
        }
    }

    /// 按候选顺序尝试润色：403 额度类失败 → 标记该模型并换下一个；其余错误原样返回。
    /// 只在收到明确的 403 时降级——网络断线等传输错误不换模型，避免串行多次超时。
    private func attemptQwenPolish(candidates: [String], url: URL, apiKey: String,
                                   makeBody: @escaping (String) -> [String: Any],
                                   completion: @escaping (Result<(String, Int, Int), Error>) -> Void) {
        guard let model = candidates.first else {
            completion(.failure(PolishError.apiError("润色模型均不可用（额度用完）")))
            return
        }
        debugLog?("Cloud ASR polish qwen attempt model=\(model)")
        callChatCompletionsWithTokens(url: url, apiKey: apiKey, body: makeBody(model)) { [weak self] result in
            if case .failure(let err) = result, case PolishError.quotaExhausted = err {
                PolishModelRouter.markExhausted(model)
                let rest = Array(candidates.dropFirst())
                if let self = self, let next = rest.first {
                    self.debugLog?("Cloud ASR polish qwen: \(model) 额度类失败(403)，自动降级到 \(next)")
                    self.attemptQwenPolish(candidates: rest, url: url, apiKey: apiKey,
                                           makeBody: makeBody, completion: completion)
                    return
                }
            }
            completion(result)
        }
    }

    // MARK: - 试用代理润色（POST /trial/polish，owner 出 API 费）

    /// 走服务器试用代理润色（POST /trial/polish）。固定用 qwen3.8-max——质量优先链的头部：
    /// 试用是转化窗口给最好的效果（2026-08-06 实测 3.7-plus 会编造整句、3.8-max 最稳还更快，
    /// 成本有服务器三层限额兜底）。故意不跟随用户的「润色设置」——那是 BYOK 用户用的。
    private func polishHosted(route: HostedRoute, text: String, outputLanguage: OutputLanguage? = nil,
                              completion: @escaping (Result<String, Error>) -> Void) {
        // 试用：qwen3.8-max（转化窗口给最好效果，2026-08-06 实测）；会员：qwen3.7-plus（与 owner 自用一致，会员成本按它测算）
        let model = route == .member ? "qwen3.7-plus" : "qwen3.8-max"
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": composedPolishSystemPrompt(outputLanguage: outputLanguage)],
                ["role": "user", "content": Self.makeCloudASRPolishUserPrompt(for: text, outputLanguage: outputLanguage)]
            ],
            "top_p": 0.8,
            "temperature": 0.7,
            "result_format": "message",
            "enable_thinking": false
        ]
        debugLog?("Cloud ASR polish: \(route == .member ? "MEMBER" : "TRIAL") via proxy, model=\(model)")
        let log = debugLog
        TrialManager.shared.hostedPost(route: route, endpoint: "polish", jsonBody: body) { data, response, error in
            if let error = error { completion(.failure(error)); return }
            let status = response?.statusCode ?? 0
            if status == 200,
               let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let message = choices.first?["message"] as? [String: Any],
               let content = message["content"] as? String {
                completion(.success(content.trimmingCharacters(in: .whitespacesAndNewlines)))
                return
            }
            // 非 200：试用层错误（含 429 润色额度用尽）。把真实原因带回上层，用于提醒用户。
            let errJson = (try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: Any]
            let msg = Self.extractAPIErrorMessage(from: errJson) ?? (route == .member ? "会员润色失败（\(status)）" : "试用润色失败（\(status)）")
            log?("Hosted polish failed: \(msg)")
            completion(.failure(PolishError.apiError(msg)))
        }
    }

    // MARK: - HTTP 调用

    private func callChatCompletionsWithTokens(url: URL, apiKey: String, body: [String: Any], completion: @escaping (Result<(String, Int, Int), Error>) -> Void) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            completion(.failure(error))
            return
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }

            guard let data = data else {
                completion(.failure(PolishError.noData))
                return
            }

            do {
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                if let json = json,
                   let choices = json["choices"] as? [[String: Any]],
                   let firstChoice = choices.first,
                   let message = firstChoice["message"] as? [String: Any],
                   let content = message["content"] as? String {
                    let usage = json["usage"] as? [String: Any]
                    let inputTokens = usage?["prompt_tokens"] as? Int ?? 0
                    let outputTokens = usage?["completion_tokens"] as? Int ?? 0
                    completion(.success((content.trimmingCharacters(in: .whitespacesAndNewlines), inputTokens, outputTokens)))
                } else if let apiMessage = Self.extractAPIErrorMessage(from: json) {
                    // 服务端业务错误：把真实原因带出去，别再吞成 parseError。
                    // 403 单独标为额度类失败（免费额度用完即停/欠费），自动路由靠它降级换模型。
                    if (response as? HTTPURLResponse)?.statusCode == 403 {
                        completion(.failure(PolishError.quotaExhausted(apiMessage)))
                    } else {
                        completion(.failure(PolishError.apiError(apiMessage)))
                    }
                } else {
                    completion(.failure(PolishError.parseError))
                }
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    private func getAPIKey() -> String? {
        // 统一走 VoicePolishConfig：secret 路由到 Keychain（env 命中后经 saveSecret 持久化）。
        // 旧版遗留的 Keychain item 由 reconcileSecrets / migrateLegacyArkKeychainItem 迁移，此处不再回写明文。
        VoicePolishConfig.shared.string(forKey: "ark_api_key", envKey: "ARK_API_KEY", persistEnvValue: true)
    }

    // MARK: - 语音问答（长按问 AI）

    static let askSystemPrompt = """
    你是使用者身邊的語音問答助手。使用者用口述語音提問，問題可能帶口語、可能不完整。請直接回答：先給結論，再展開要點；一律使用繁體中文（台灣習慣用詞與正體中文）回答（若使用者明確要求特定語言則遵照其要求）；不要客套，不要複述問題，結尾不要追問「要不要……」；不確定就說不確定。篇幅隨問題而定：簡單問題兩三句說完，複雜問題可以分組展開，但不要灌水。
    排版用輕量 Markdown（面板會渲染）：段落之間空一行，每段只說一件事；列舉多項時逐條分行，用「1. 」或「- 」開頭；內容分幾組時用「### 組名」做小標題；每條裡的關鍵詞用 **粗體** 標出（一條最多一處）；不用表格、引用、程式碼區塊。
    """

    /// 模型沒有時鐘：每次提問都把「現在」寫進提示詞。不寫的話它只能從搜到的網頁裡猜今天幾號
    /// （網頁常是前一兩天發的，2026-09-11 實測 4 次全答成前一天），問「現在幾點」也答不出。
    static func askTimeLine(now: Date = Date(), timeZone: TimeZone = .current) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: now)
        let week = ["日", "一", "二", "三", "四", "五", "六"][max(0, min(6, (c.weekday ?? 1) - 1))]
        let offset = timeZone.secondsFromGMT(for: now)
        let zone: String
        if offset == 8 * 3600 {
            zone = "台灣/台北時間"
        } else {
            let h = offset / 3600, m = abs(offset % 3600) / 60
            zone = m == 0 ? String(format: "UTC%+d", h) : String(format: "UTC%+d:%02d", h, m)
        }
        return "當前時間：\(c.year ?? 0)年\(c.month ?? 0)月\(c.day ?? 0)日 星期\(week) "
            + String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0) + "（\(zone)）。"
    }

    /// 問題裡帶時效詞（今天/最新/價格…）→ 連網時強制搜尋。
    static func isTimeSensitive(_ question: String) -> Bool {
        let cues = ["今天", "現在", "目前", "最近", "最新", "新聞", "價格", "股價", "匯率", "天氣", "幾號", "星期",
                                 "多少錢", "發布", "更新", "今年", "本週", "這週", "昨天", "明天", "上市", "2025", "2026", "2027"]
        return cues.contains { question.contains($0) }
    }

    /// 用當前設定的潤色模型回答一個問題（千問附帶連網搜尋；問題帶時效詞時強制搜）。
    /// history：本話題之前的問答對（多輪續聊時帶上，最多 6 輪）。
    /// onPartial：流式輸出，每收到一段就回調累計文字；沒配 key 的試用使用者走代理（不流式，只回調一次）。
    public func answer(question: String,
                       history: [(question: String, answer: String)] = [],
                       onPartial: ((String) -> Void)? = nil,
                       completion: @escaping (Result<String, Error>) -> Void) {
        var messages: [[String: Any]] = [["role": "system", "content": Self.askSystemPrompt + "\n" + Self.askTimeLine()]]
        for turn in history.suffix(6) {
            messages.append(["role": "user", "content": turn.question])
            messages.append(["role": "assistant", "content": turn.answer])
        }
        messages.append(["role": "user", "content": question])

        // 會員優先走會員：有自己的 Key 也走託管問答（與潤色同一條規則）
        let ownProvider = polishProvider()
        let preferHosted = ownProvider != nil && HostedRoute.current(ownKeyConfigured: true) == .member
        guard let provider = ownProvider, !preferHosted else {
            let providerSetting = VoicePolishConfig.shared.string(forKey: "polish_provider")
            let hostedRoute = HostedRoute.current(ownKeyConfigured: ownProvider != nil)
            if !Self.isPolishDisabled(provider: providerSetting) && hostedRoute != .none {
                // 託管問答（試用/會員）一律 qwen3.7-plus，與 owner 自用一致（Ray 2026-09-12）；連網與強制搜尋由伺服器放行
                var body: [String: Any] = ["model": "qwen3.7-plus", "messages": messages, "top_p": 0.8, "temperature": 0.5,
                                           "result_format": "message", "enable_thinking": false, "enable_search": true]
                if Self.isTimeSensitive(question) { body["search_options"] = ["forced_search": true] }
                TrialManager.shared.hostedPost(route: hostedRoute, endpoint: "polish", jsonBody: body) { data, response, error in
                    if let error { completion(.failure(error)); return }
                    if let data, (response?.statusCode ?? 0) == 200,
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let content = ((json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String {
                        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
                        onPartial?(text)
                        completion(.success(text))
                    } else {
                        let errJson = (try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: Any]
                        completion(.failure(PolishError.apiError(Self.extractAPIErrorMessage(from: errJson) ?? "問答請求失敗（\(response?.statusCode ?? 0)）")))
                    }
                }
                return
            }
            completion(.failure(PolishError.noAPIKey))
            return
        }
        // 千問連網預設由模型自己判斷要不要搜，它覺得會答的就不搜、答案可能過期；
        // 問題裡帶時效詞時強制搜，其他問題維持智慧判斷。
        let forceSearch = Self.isTimeSensitive(question)
        debugLog?("Ask provider=\(provider.name) model=\(provider.model) forceSearch=\(forceSearch) history=\(history.count)")
        func makeBody(_ model: String, search: Bool) -> [String: Any] {
            var body: [String: Any] = ["model": model, "messages": messages, "stream": true]
            if provider.name == "qwen" {
                body["top_p"] = 0.8; body["temperature"] = 0.5; body["enable_thinking"] = false
                if search {
                    body["enable_search"] = true
                    if forceSearch { body["search_options"] = ["forced_search": true] }
                }
            } else if provider.name == "gemini" || provider.name == "openai" || provider.name == "groq" {
                body["temperature"] = 0.5
                body["max_tokens"] = 2000
            } else {
                body["temperature"] = 0.5; body["max_tokens"] = 1200; body["thinking"] = ["type": "disabled"]
            }
            return body
        }
        let candidates: [String] = provider.name == "qwen"
            ? (PolishModelRouter.isAuto(provider.model) ? PolishModelRouter.candidates(for: provider.model) : [provider.model])
            : [provider.model]
        func attempt(_ index: Int, search: Bool) {
            guard index < candidates.count else {
                completion(.failure(PolishError.apiError("問答模型均不可用（額度用完）")))
                return
            }
            let model = candidates[index]
            streamChat(url: provider.url, apiKey: provider.apiKey, body: makeBody(model, search: search), onPartial: onPartial) { [weak self] result in
                switch result {
                case .success(let text):
                    if !text.isEmpty { TrialManager.shared.recordSelfKeyUsage(chars: text.count) }
                    completion(.success(text))
                case .failure(let err):
                    if case PolishError.quotaExhausted = err {
                        PolishModelRouter.markExhausted(model)
                        self?.debugLog?("Ask: \(model) 額度類失敗，降級到下一個")
                        attempt(index + 1, search: search)
                    } else if search, case PolishError.apiError = err {
                        self?.debugLog?("Ask with enable_search failed, retrying without: \(err)")
                        attempt(index, search: false)
                    } else {
                        completion(.failure(err))
                    }
                }
            }
        }
        attempt(0, search: provider.name == "qwen")
    }

    /// OpenAI 兼容的流式对话（SSE）：每收到一段增量就回调累计文本，结束时给完整文本。
    private func streamChat(url: URL, apiKey: String, body: [String: Any],
                            onPartial: ((String) -> Void)?,
                            completion: @escaping (Result<String, Error>) -> Void) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 90
        do { request.httpBody = try JSONSerialization.data(withJSONObject: body) } catch { completion(.failure(error)); return }
        let reader = SSEReader(onPartial: onPartial, completion: completion)
        let session = URLSession(configuration: .default, delegate: reader, delegateQueue: nil)
        reader.session = session
        session.dataTask(with: request).resume()
    }

    /// 逐块解析 SSE，把 delta.content 累计起来；非 200 时把服务端错误原样带出（403 = 额度类）
    private final class SSEReader: NSObject, URLSessionDataDelegate {
        private let onPartial: ((String) -> Void)?
        private let completion: (Result<String, Error>) -> Void
        private var buffer = Data()
        private var accumulated = ""
        private var statusCode = 200
        private var errorBody = Data()
        private var finished = false
        var session: URLSession?

        init(onPartial: ((String) -> Void)?, completion: @escaping (Result<String, Error>) -> Void) {
            self.onPartial = onPartial
            self.completion = completion
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            statusCode = (response as? HTTPURLResponse)?.statusCode ?? 200
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard statusCode == 200 else { errorBody.append(data); return }
            buffer.append(data)
            while let range = buffer.range(of: Data([0x0A])) {   // 按行切
                let lineData = buffer.subdata(in: 0..<range.lowerBound)
                buffer.removeSubrange(0...range.lowerBound)
                guard let line = String(data: lineData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { continue }
                guard let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
                      let choice = (json["choices"] as? [[String: Any]])?.first else { continue }
                let piece = ((choice["delta"] as? [String: Any])?["content"] as? String)
                    ?? ((choice["message"] as? [String: Any])?["content"] as? String)
                if let piece, !piece.isEmpty {
                    accumulated += piece
                    let snapshot = accumulated
                    DispatchQueue.main.async { self.onPartial?(snapshot) }
                }
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            defer { self.session?.finishTasksAndInvalidate() }
            guard !finished else { return }
            finished = true
            if let error { completion(.failure(error)); return }
            guard statusCode == 200 else {
                let json = try? JSONSerialization.jsonObject(with: errorBody) as? [String: Any]
                let message = AIPolisher.extractAPIErrorMessage(from: json) ?? "HTTP \(statusCode)"
                completion(.failure(statusCode == 403 ? PolishError.quotaExhausted(message) : PolishError.apiError(message)))
                return
            }
            let text = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
            completion(text.isEmpty ? .failure(PolishError.parseError) : .success(text))
        }
    }

    // MARK: - 日志

    public func writePolishLog(asr: String, output: String, durationMs: Int, inputTokens: Int = 0, outputTokens: Int = 0, id: String? = nil, audioFile: String? = nil) {
        let entry = makePolishLogEntry(
            asr: asr,
            output: output,
            durationMs: durationMs,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            id: id ?? UUID().uuidString,
            audioFile: audioFile
        )

        // 写入本地记录文件（不外传）
        appendToPendingLog(entry)
    }

    /// 问 AI 的一轮问答写进历史（问题存 asr、回答存 output），同一话题共用 thread
    public func writeAskLog(question: String, answer: String, thread: String, durationMs: Int) {
        let entry = makePolishLogEntry(asr: question, output: answer, durationMs: durationMs, inputTokens: 0, outputTokens: 0,
                                       id: UUID().uuidString, audioFile: nil, kind: "ask", thread: thread)
        appendToPendingLog(entry)
    }

    func makePolishLogEntry(asr: String, output: String, durationMs: Int, inputTokens: Int, outputTokens: Int, id: String? = nil, audioFile: String? = nil, kind: String? = nil, thread: String? = nil) -> PolishLog {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return PolishLog(
            time: formatter.string(from: Date()),
            app: polishLogAppNameProvider?() ?? "鍵盤",
            asr: asr,
            output: output,
            duration_ms: durationMs,
            input_tokens: inputTokens,
            output_tokens: outputTokens,
            id: id,
            audioFile: audioFile,
            kind: kind,
            thread: thread
        )
    }

    public static func historyLogFileURL() -> URL? {
        #if os(macOS)
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/voicepolish/polish_log.jsonl")
        #else
        return pendingLogFileURL()
        #endif
    }

    private static func pendingLogFileURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.com.voicepolish.shared")?
            .appendingPathComponent("polish_log_pending.jsonl")
    }

    private func appendToPendingLog(_ entry: PolishLog) {
        // 「不保存資料」：文字不落盤，連剛生成的音訊也一併刪除，避免留下孤兒檔案
        if Self.currentHistoryRetention() == .off {
            AudioClipStore.defaultStore().delete(fileName: entry.audioFile)
            return
        }

        guard let enc = HistoryCrypto.defaultEncryptor(),
              let encryptedLine = HistoryCrypto.encodeLine(entry, enc: enc),
              let lineData = (encryptedLine + "\n").data(using: .utf8) else {
            AudioClipStore.defaultStore().delete(fileName: entry.audioFile)
            NSLog("[history] encryption unavailable, skipping history record")
            return
        }

        guard let logFile = Self.historyLogFileURL() else { return }
        let audioStore = AudioClipStore.defaultStore()
        let retention = Self.currentHistoryRetention()

        // 追加 + 裁剪在同一把鎖裡：設定視窗那邊的整檔案重寫若插在中間，這條就丟了。
        HistoryFileLock.withLock {
            try? FileManager.default.createDirectory(at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)

            if FileManager.default.fileExists(atPath: logFile.path) {
                if let handle = try? FileHandle(forWritingTo: logFile) {
                    handle.seekToEndOfFile()
                    handle.write(lineData)
                    handle.closeFile()
                }
            } else {
                try? lineData.write(to: logFile)
            }

            Self.pruneLogFile(at: logFile, retention: retention, encryptor: enc) { removed in
                audioStore.delete(fileName: removed.audioFile)  // 裁剪過期記錄時一併刪除音訊
            }
        }
    }

    public static func currentHistoryRetention(config: VoicePolishConfig = .shared) -> HistoryRetention {
        guard let raw = config.string(forKey: HistoryRetention.configKey),
              let retention = HistoryRetention(rawValue: raw) else {
            return HistoryRetention.defaultValue
        }
        return retention
    }

    public static func shouldKeepPolishLog(_ log: PolishLog, retention: HistoryRetention, now: Date = Date()) -> Bool {
        guard let cutoff = retention.cutoffDate(now: now),
              let date = polishLogDate(from: log.time) else {
            return true
        }
        return date >= cutoff
    }

    @discardableResult
    public static func pruneLogFile(at fileURL: URL, retention: HistoryRetention, now: Date = Date(), encryptor: Encryptor? = nil, onRemove: ((PolishLog) -> Void)? = nil) -> Int {
        guard retention != .forever else { return 0 }

        return HistoryFileLock.withLock { () -> Int in
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return 0 }

            let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
            var keptLines: [String] = []
            var removedCount = 0

            for line in lines where !line.isEmpty {
                let rawLine = String(line)
                guard let log = HistoryCrypto.decodeLine(rawLine, enc: encryptor) else {
                    keptLines.append(rawLine)
                    continue
                }

                if shouldKeepPolishLog(log, retention: retention, now: now) {
                    keptLines.append(rawLine)
                } else {
                    removedCount += 1
                    onRemove?(log)  // 讓呼叫方刪掉該條對應的音訊檔案
                }
            }

            guard removedCount > 0 else { return 0 }

            let nextContent = keptLines.joined(separator: "\n")
                + (keptLines.isEmpty ? "" : "\n")
            try? nextContent.write(to: fileURL, atomically: true, encoding: .utf8)
            return removedCount
        }
    }

    private static func polishLogDate(from raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: raw)
    }

    public enum PolishError: LocalizedError {
        case noAPIKey
        case noData
        case parseError
        case apiError(String)   // 伺服端回傳的業務錯誤（鑑權/限流等），帶真實原因
        case quotaExhausted(String)   // 403 額度類失敗（免費額度用完即停/欠費），自動路由靠它降級

        public var errorDescription: String? {
            switch self {
            case .noAPIKey: return "未設定潤色模型的 API 金鑰"
            case .noData: return "潤色服務未回傳資料"
            case .parseError: return "潤色回傳內容無法解析"
            case .apiError(let msg): return msg
            case .quotaExhausted(let msg): return msg
            }
        }
    }

    /// 從 OpenAI 相容 / DashScope 的錯誤回應裡取清楚原因：
    /// 相容 {"error":{"message":...}}、{"message":...,"code":...}、{"error":"..."}。
    static func extractAPIErrorMessage(from json: [String: Any]?) -> String? {
        guard let json = json else { return nil }
        if let err = json["error"] as? [String: Any] {
            let code = err["code"] as? String
            let type = err["type"] as? String
            let m = err["message"] as? String
            if let friendly = friendlyProviderError(code: code, type: type, message: m) { return friendly }
            if let m = m, !m.isEmpty { return m }
            if let c = code, !c.isEmpty { return c }
        }
        if let err = json["error"] as? String, !err.isEmpty {
            return friendlyProviderError(code: nil, type: nil, message: err) ?? err
        }
        if let m = json["message"] as? String, !m.isEmpty {
            let code = json["code"] as? String
            if let friendly = friendlyProviderError(code: code, type: nil, message: m) { return friendly }
            if let code = code, !code.isEmpty { return "\(m)（\(code)）" }
            return m
        }
        return nil
    }

    /// 把服務商最常見的兩類錯誤翻成能照著處理的繁體中文；認不出的回傳 nil、保留原話。
    static func friendlyProviderError(code: String?, type: String?, message: String?) -> String? {
        let c = (code ?? "").lowercased()
        let t = (type ?? "").lowercased()
        let m = (message ?? "").lowercased()
        let tag = (code?.isEmpty == false) ? "（\(code!)）" : ""

        if c == "invalid_api_key" || c == "invalidapikey" || c == "authenticationerror" || t == "unauthorized"
            || m.contains("incorrect api key") || m.contains("api key format is incorrect")
            || m.contains("didn't provide an api key") || m.contains("invalid api key") {
            return "API Key 無效，請檢查是否複製完整\(tag)"
        }
        if c == "arrearage" || c == "accountoverdueerror" || c == "insufficient_quota"
            || m.contains("in good standing") || m.contains("arrearage") || m.contains("overdue")
            || m.contains("quota exceeded") || m.contains("enough balance") {
            return "帳號欠費或免費額度已用完，請至服務商控制台檢查\(tag)"
        }
        if c == "quotaexceeded" || c == "ratelimitexceeded" || c == "throttling" || c.hasPrefix("throttling.")
            || c == "limit_requests" || m.contains("rate limit") || m.contains("too many requests") {
            return "請求太頻繁或額度超限，請稍後再試\(tag)"
        }
        return nil
    }
}
