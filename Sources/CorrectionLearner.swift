import Foundation

/// 使用者把辨識結果中的一段字改掉時，整理出可加入詞庫的「原詞 => 正確寫法」。
struct LearnedCorrection: Equatable, Sendable {
    let wrong: String
    let right: String

    var rule: String { "\(wrong) => \(right)" }
}

/// `original` 是 iSay 輸入的文字；`edited` 是同一位置目前的文字，後面可能多出使用者接著打的字。
/// 只接受單一處、長度不超過 12 字的替換；刪除、整段重寫或只改一個字都不提議，避免學到太泛的規則。
func learnedCorrection(original: String, edited: String) -> LearnedCorrection? {
    let o = Array(original), c = Array(edited)
    let maxChange = 12
    var prefix = 0
    while prefix < o.count, prefix < c.count, o[prefix] == c[prefix] { prefix += 1 }
    guard prefix < o.count else { return nil }

    // 找最長的「原文結尾仍保留」片段；至少保留一個字，才知道修改到哪裡結束。
    let longest = o.count - prefix - 1
    let shortest = max(1, o.count - prefix - maxChange)
    guard longest >= shortest else { return nil }
    var match: (kept: Int, end: Int)?
    search: for kept in stride(from: longest, through: shortest, by: -1) {
        let tail = o[(o.count - kept)...]
        let upper = min(c.count - kept, prefix + maxChange)
        guard upper >= prefix else { continue }
        for end in prefix...upper where c[end..<(end + kept)].elementsEqual(tail) {
            match = (kept, end)
            break search
        }
    }
    guard let match, match.end > prefix else { return nil }

    var wrongStart = prefix, wrongEnd = o.count - match.kept
    var rightStart = prefix, rightEnd = match.end
    // 英文與數字補成完整單字，例如 Gitlab => GitHub，而不是 lab => Hub。
    while wrongStart > 0, isASCIIWord(o[wrongStart - 1]), isASCIIWord(o[wrongStart]) || isASCIIWord(c[rightStart]) {
        wrongStart -= 1; rightStart -= 1
    }
    while wrongEnd < o.count, isASCIIWord(o[wrongEnd]), isASCIIWord(o[wrongEnd - 1]) || isASCIIWord(c[rightEnd - 1]) {
        wrongEnd += 1; rightEnd += 1
    }
    // 中文太短容易誤改別的詞，往兩側補到至少 3 個字，但不跨過空白與標點。
    while wrongEnd - wrongStart < 3 {
        if wrongStart > 0, !isBoundary(o[wrongStart - 1]) {
            wrongStart -= 1; rightStart -= 1
        } else if wrongEnd < o.count, !isBoundary(o[wrongEnd]) {
            wrongEnd += 1; rightEnd += 1
        } else {
            break
        }
    }

    let wrong = String(o[wrongStart..<wrongEnd]), right = String(c[rightStart..<rightEnd])
    guard wrong != right, wrong.count >= 2, right.count >= 1,
          !wrong.hasPrefix("#"), !(wrong + right).contains("=>"),
          !(wrong + right).contains(where: \.isNewline),
          wrong.trimmingCharacters(in: .whitespaces) == wrong,
          right.trimmingCharacters(in: .whitespaces) == right else { return nil }
    return LearnedCorrection(wrong: wrong, right: right)
}

private func isASCIIWord(_ character: Character) -> Bool {
    character.isASCII && (character.isLetter || character.isNumber || character == "_")
}

private func isBoundary(_ character: Character) -> Bool {
    character.isWhitespace || character.isPunctuation || character.isSymbol
}
