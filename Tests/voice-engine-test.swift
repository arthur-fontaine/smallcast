// Every CoreML speech engine against a spoken fixture; each leg skips with a reason when its
// model is not downloaded, so CI (which has none) only checks that the runners compile.

import AVFoundation
import Foundation

@main
@MainActor
struct VoiceEngineTests {
    static var failures = 0
    static var passes = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() {
            passes += 1
        } else {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    static let store = VoiceModelStore(
        root: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Application Support/com.smallcast.app.dev/voice-models"))

    /// `path=expected text=language;…`: 16 kHz mono WAVs and the words each must contain.
    static var fixtures: [(URL, String, VoiceLanguage)] {
        let raw = ProcessInfo.processInfo.environment["SMALLCAST_VOICE_FIXTURES"] ?? ""
        return raw.split(separator: ";").compactMap { entry in
            let parts = entry.split(separator: "=", maxSplits: 2).map(String.init)
            guard parts.count == 3 else { return nil }
            return (URL(fileURLWithPath: parts[0]), parts[1], VoiceLanguage.named(parts[2]))
        }
    }

    /// The engines that only ever hear English; every other one is asked to detect the language.
    static let englishOnly: Set<VoiceEngine> = [.parakeetFlash, .parakeetV2]
    /// Told the fixture's language: Cohere refuses to guess, and Apple Speech would use this Mac's.
    static let told: Set<VoiceEngine> = [.cohereTranscribe, .appleSpeech]

    static func main() async {
        let only = ProcessInfo.processInfo.environment["SMALLCAST_VOICE_ENGINES"]?
            .split(separator: ",").map(String.init)
        for engine in VoiceEngine.allCases where engine != .appleSpeech {
            if let only, !only.contains(engine.rawValue) { continue }
            await run(engine)
        }
        if only?.contains(VoiceEngine.appleSpeech.rawValue) == true { await run(.appleSpeech) }
        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    static func run(_ engine: VoiceEngine) async {
        guard store.status(for: engine) == .installed else {
            print("skip: \(engine.title) is not downloaded")
            return
        }
        let fixtures = self.fixtures
        guard !fixtures.isEmpty else {
            print("skip: no SMALLCAST_VOICE_FIXTURES for \(engine.title)")
            return
        }
        do {
            let started = Date()
            let transcriber = try await VoiceTranscriberFactory.load(engine, root: store.root)
            let loaded = Date().timeIntervalSince(started)
            for (file, expected, language) in fixtures {
                if englishOnly.contains(engine), language.code != "en" { continue }
                let audio = try read(file)
                // Twice: the first call pays for CoreML specialising the graph, the second is the truth.
                let asked = told.contains(engine) ? language : VoiceLanguage.auto
                _ = try await transcriber.transcribe(audio, language: asked)
                let clock = Date()
                let text = try await transcriber.transcribe(audio, language: asked)
                let took = Date().timeIntervalSince(clock)
                let normalized = text.lowercased()
                expect(
                    normalized.contains(expected.lowercased()),
                    "\(engine.title) hears “\(expected)” in \(file.lastPathComponent), got “\(text)”")
                let seconds = String(format: "%.2f", took)
                let heard = String(format: "%.1f", audio.duration)
                print("  \(engine.title): \(seconds) s for \(heard) s (load \(String(format: "%.1f", loaded)) s) → \(text)")
            }
        } catch {
            failures += 1
            print("FAIL: \(engine.title) threw \(error)")
        }
    }

    static func read(_ url: URL) throws -> VoiceAudio {
        let file = try AVAudioFile(forReading: url)
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))
        else { throw VoiceTranscriptionError.speechUnavailable("bad fixture") }
        if file.processingFormat == format {
            try file.read(into: buffer)
        } else {
            guard let raw = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
                let converter = AVAudioConverter(from: file.processingFormat, to: format)
            else { throw VoiceTranscriptionError.speechUnavailable("bad fixture") }
            try file.read(into: raw)
            var fed = false
            var error: NSError?
            converter.convert(to: buffer, error: &error) { _, status in
                if fed {
                    status.pointee = .endOfStream
                    return nil
                }
                fed = true
                status.pointee = .haveData
                return raw
            }
            if let error { throw error }
        }
        let count = Int(buffer.frameLength)
        return VoiceAudio(samples: Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: count)))
    }
}
