import Foundation

private let punctuation = try! NSRegularExpression(
    pattern: #"`[^`]+`|(?:[a-zA-Z][a-zA-Z0-9+.-]*://|(?i:www\.))[^\s`]+|(?<=\p{Han})[,;:!?]|[,;](?=\p{Han})|(?<=\p{Han})\.(?=\s|$)|\p{Han}$"#
)

func punctuateTranscript(_ text: String) -> String {
    var result = ""
    var cursor = text.startIndex
    punctuation.enumerateMatches(in: text, range: NSRange(text.startIndex..., in: text)) { match, _, _ in
        guard let match, let range = Range(match.range, in: text) else { return }
        let token = text[range]
        guard let mark = token.first, token.dropFirst().isEmpty else { return }
        result += text[cursor..<range.lowerBound]
        switch mark {
        case ",": result += "，"
        case ";": result += "；"
        case ":": result += "："
        case "!": result += "！"
        case "?": result += "？"
        case ".": result += "。"
        default:
            result.append(mark)
            result += mark == "嗎" ? "？" : "。"
        }
        cursor = range.upperBound
    }
    guard cursor != text.startIndex else { return text }
    result += text[cursor...]
    return result
}
