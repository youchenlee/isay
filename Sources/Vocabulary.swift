import Foundation

struct Vocabulary {
    static let starter = """
    # 每行一個常用詞。模型會優先參考這些詞。
    # 例如：小明科技、Cloud Run（各寫一行）
    # 常被辨識成別的字？加一行：原詞 => 正確寫法
    # 例如：小名科技 => 小明科技

    """

    private let terms: [String]
    private let replacements: [String: String]

    init(_ contents: String) {
        var terms: [String] = []
        var replacements: [String: String] = [:]
        for line in contents.split(whereSeparator: \.isNewline) {
            let entry = line.trimmingCharacters(in: .whitespaces)
            guard !entry.isEmpty, !entry.hasPrefix("#") else { continue }
            guard let arrow = entry.range(of: "=>") else {
                terms.append(entry)
                continue
            }
            let wrong = entry[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
            let right = entry[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !wrong.isEmpty, !right.isEmpty else { continue }
            replacements[wrong] = right
        }
        self.terms = terms
        self.replacements = replacements
    }

    struct Prompt: Sendable {
        let hints: [String]
        /// 游標前文字；只有確認放得進模型上限時才會帶入。
        let context: String
        let total: Int
        let replacementCount: Int
        /// true：已用 Whisper 的分詞器確認整段提示放得進模型上限。
        let fitsModel: Bool

        var text: String { hints.isEmpty ? context : hints.joined(separator: "、") + "。" + context }
    }

    /// 去重後的提示詞，依詞庫順序排列。
    var candidates: [String] {
        var seen = Set<String>()
        return terms.filter { seen.insert($0).inserted }
    }

    func prompt(hints: [String], context: String = "", fitsModel: Bool) -> Prompt {
        Prompt(hints: hints, context: context, total: candidates.count,
               replacementCount: replacements.count, fitsModel: fitsModel)
    }

    /// 無法用 tokenizer 核對時的保守估計。Whisper 只保留提示的最後一段，超出時丟的是開頭的高優先詞。
    var fallbackHints: [String] {
        var hints: [String] = []
        var remainingBytes = 400
        for term in candidates {
            let size = term.utf8.count + 3
            guard size <= remainingBytes else { continue }
            hints.append(term)
            remainingBytes -= size
        }
        return hints
    }

    func correct(_ text: String) -> String {
        guard !replacements.isEmpty else { return text }
        let patterns = replacements.keys.sorted { $0.count > $1.count }.map { term in
            let start = term.utf8.first.map(Self.isASCIIWordByte) == true ? "(?<![A-Za-z0-9_])" : ""
            let end = term.utf8.last.map(Self.isASCIIWordByte) == true ? "(?![A-Za-z0-9_])" : ""
            return start + NSRegularExpression.escapedPattern(for: term) + end
        }
        guard let regex = try? NSRegularExpression(pattern: patterns.joined(separator: "|")) else { return text }
        var result = ""
        var cursor = text.startIndex
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            result += text[cursor..<range.lowerBound]
            result += replacements[String(text[range])] ?? String(text[range])
            cursor = range.upperBound
        }
        result += text[cursor...]
        return result
    }

    private static func isASCIIWordByte(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || byte == 95
    }
}
