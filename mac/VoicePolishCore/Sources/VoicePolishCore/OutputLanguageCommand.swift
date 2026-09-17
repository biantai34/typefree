import Foundation

/// 语音口令：用户在一句话的开头或结尾说「用英文」「翻译成英文」「English」，本次输出英文。
/// 识别完全用程序规则，不交给模型「领会」：
/// - 只认句首和句尾，中间出现一律当正文；
/// - 句首口令后面要有停顿（标点或空格），避免「用英文写信的人越来越少」这类正文被误认；
/// - 口令前面紧跟「不要 / 别 / 不用」等否定词的不算（「这段话不要翻译成英文」是正文）；
/// - 去掉口令后正文要有实质内容，只有口令的整句当正文。
public struct OutputLanguageCommand: Equatable {
    public enum Position: String { case leading, trailing }

    public let target: OutputLanguage
    public let position: Position
    public let matchedPhrase: String
    /// 去掉口令后的正文（已去掉口令旁边的标点）
    public let strippedText: String

    public static let configKey = OutputLanguage.commandEnabledConfigKey
    static let negations: [String] = ["不要", "別", "不用", "不能", "無需", "不需要", "不必", "不會", "沒有", "不是", "不", "沒", "别", "无需", "不会", "没有", "没"]
    /// 正文至少要有这么多有意义的字符，否则整句当正文
    static let minimumContentCharacters = 3

    public static func detect(in text: String, languages: [OutputLanguage] = OutputLanguage.builtin) -> OutputLanguageCommand? {
        let trimmed = trimEdges(text)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        var pairs: [(String, OutputLanguage)] = []
        for language in languages where language.enabled {
            for phrase in language.phrases {
                let p = phrase.trimmingCharacters(in: .whitespaces)
                if !p.isEmpty { pairs.append((p, language)) }
            }
        }
        pairs.sort { $0.0.count > $1.0.count }   // 长口令优先（"翻译成英文" 先于 "用英文"）

        for (phrase, language) in pairs {
            let p = phrase.lowercased()
            // 英文口令（English / in English）在英文句子里本来就是普通单词，空格不算停顿，必须有标点隔开
            let needsPunctuation = phrase.unicodeScalars.contains { isASCIILetter($0) }
            // 句尾
            if lower.hasSuffix(p) {
                let bodyEnd = trimmed.index(trimmed.endIndex, offsetBy: -phrase.count)
                let body = String(trimmed[..<bodyEnd])
                let boundaryOK = !needsPunctuation || hasPunctuationBoundary(body.unicodeScalars.reversed())
                if boundaryOK, !isNegated(before: body), let stripped = validBody(trimEdges(body)) {
                    return OutputLanguageCommand(target: language, position: .trailing, matchedPhrase: phrase, strippedText: stripped)
                }
            }
            // 句首：口令后面必须有停顿（中文口令：标点或空格；英文口令：标点）
            if lower.hasPrefix(p) {
                let afterStart = trimmed.index(trimmed.startIndex, offsetBy: phrase.count)
                let rest = String(trimmed[afterStart...])
                let boundaryOK = needsPunctuation
                    ? hasPunctuationBoundary(rest.unicodeScalars)
                    : (rest.unicodeScalars.first.map(isSeparator) ?? false)
                if boundaryOK, let stripped = validBody(trimEdges(rest)) {
                    return OutputLanguageCommand(target: language, position: .leading, matchedPhrase: phrase, strippedText: stripped)
                }
            }
        }
        return nil
    }

    // MARK: - 细节

    private static let separators = CharacterSet(charactersIn: "，。、！？；：,.!?;:\"“”‘’'()（）[]【】…—-~～ \t\n\r")

    static func isSeparator(_ scalar: UnicodeScalar) -> Bool { separators.contains(scalar) }
    static func isASCIILetter(_ scalar: UnicodeScalar) -> Bool { (65...90).contains(Int(scalar.value)) || (97...122).contains(Int(scalar.value)) }
    /// 跳过空白后，紧邻的第一个字符是标点
    static func hasPunctuationBoundary<S: Sequence>(_ scalars: S) -> Bool where S.Element == UnicodeScalar {
        for sc in scalars {
            if sc == " " || sc == "\t" { continue }
            return isSeparator(sc)
        }
        return false
    }

    static func trimEdges(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.drop(while: isSeparator).reversed().drop(while: isSeparator).reversed()))
    }

    /// 口令前面（去掉标点后）紧跟否定词 → 是正文，不是口令
    static func isNegated(before body: String) -> Bool {
        let tail = trimEdges(body)
        return negations.contains { tail.hasSuffix($0) }
    }

    /// 正文要有实质内容
    static func validBody(_ body: String) -> String? {
        let meaningful = body.unicodeScalars.filter { $0.properties.isAlphabetic || $0.properties.numericType != nil }.count
        return meaningful >= minimumContentCharacters ? body : nil
    }
}
