import Foundation
import Darwin

struct Transcriber: Sendable {
    let directory: URL
    let whisper: URL
    let openCC: URL

    var vocabularyFile: URL { directory.appendingPathComponent("詞庫.txt") }
    private var model: URL { directory.appendingPathComponent("ggml-large-v3-turbo-q5_0.bin") }
    private var vad: URL { directory.appendingPathComponent("ggml-silero-v6.2.0.bin") }

    var isReady: Bool {
        let files = FileManager.default
        return files.isExecutableFile(atPath: whisper.path) && files.isExecutableFile(atPath: openCC.path)
            && files.isReadableFile(atPath: model.path) && files.isReadableFile(atPath: vad.path)
    }

    func transcribe(_ audio: URL, context: String, onPrompt: @Sendable (Vocabulary.Prompt) -> Void) throws -> String {
        let folder = audio.deletingLastPathComponent()
        let output = folder.appendingPathComponent("whisper")
        let entries: String
        do { entries = try String(contentsOf: vocabularyFile, encoding: .utf8) }
        catch CocoaError.fileReadNoSuchFile { entries = "" }
        let vocabulary = Vocabulary(entries)
        let raw = output.appendingPathExtension("txt")
        let traditional = folder.appendingPathComponent("traditional.txt")

        let prompt = selectPrompt(vocabulary, context: context)
        try run(whisper, ["-m", model.path, "-f", audio.path, "-l", "zh", "--prompt", prompt.text,
                          "--vad", "-vm", vad.path, "-otxt", "-of", output.path, "-np"],
                timeout: 30, failure: "語音辨識失敗，請再試一次。",
                onStart: { onPrompt(prompt) })
        guard FileManager.default.fileExists(atPath: raw.path) else { return "" }
        let recognized = try String(contentsOf: raw, encoding: .utf8)
        guard recognized.contains(where: { !$0.isWhitespace }) else { return "" }
        try run(openCC, ["-c", "s2twp.json", "-i", raw.path, "-o", traditional.path],
                timeout: 5, failure: "轉成正體中文時發生錯誤。")
        let text = try String(contentsOf: traditional, encoding: .utf8)
        let singleLine = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return punctuateTranscript(vocabulary.correct(singleLine))
    }

    /// 用 App 內附的 isay-prompt 依 Whisper 分詞器挑詞，並確認游標前文字放得進；
    /// 失敗時退回保守的位元組估計，且不帶游標前文字。
    private func selectPrompt(_ vocabulary: Vocabulary, context: String) -> Vocabulary.Prompt {
        let candidates = vocabulary.candidates
        let ggml = whisper.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("opt/ggml/libexec")
        guard !(candidates.isEmpty && context.isEmpty),
              let selector = Bundle.main.url(forAuxiliaryExecutable: "isay-prompt") else {
            return vocabulary.prompt(hints: vocabulary.fallbackHints, fitsModel: false)
        }
        let process = Process()
        process.executableURL = selector
        process.arguments = [ggml.path, model.path]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch {
            return vocabulary.prompt(hints: vocabulary.fallbackHints, fitsModel: false)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if process.isRunning { process.terminate() } }
        input.fileHandleForWriting.write(Data((([context] + candidates).joined(separator: "\n") + "\n").utf8))
        try? input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard exited.wait(timeout: .now() + 1) == .success,
              process.terminationReason == .exit, process.terminationStatus == 0 else {
            if process.isRunning { process.terminate() }
            return vocabulary.prompt(hints: vocabulary.fallbackHints, fitsModel: false)
        }
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard let first = lines.first, first == "0" || first == "1" else {
            return vocabulary.prompt(hints: vocabulary.fallbackHints, fitsModel: false)
        }
        lines.removeFirst()
        return vocabulary.prompt(hints: lines.filter { !$0.isEmpty }, context: first == "1" ? context : "", fitsModel: true)
    }

    func run(_ executable: URL, _ arguments: [String], timeout: Double, failure: String,
             onStart: () -> Void = {}) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { throw SpeechError(message: failure) }
        onStart()
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + .milliseconds(250)) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            throw SpeechError(message: "語音整理逾時，請再按住右 ⌘ 錄一次。")
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw SpeechError(message: failure)
        }
    }
}

struct SpeechError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
