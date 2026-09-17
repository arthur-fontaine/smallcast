import AVFoundation
import Foundation
import Speech

/// macOS's own on-device recognizer: `SpeechAnalyzer` with a `SpeechTranscriber` module.
final class AppleSpeechTranscriber: VoiceTranscriber, Sendable {
    func transcribe(_ audio: VoiceAudio, language: VoiceLanguage) async throws -> String {
        let wanted = language.isAuto ? Locale.current : Locale(identifier: language.code)
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) else {
            throw VoiceTranscriptionError.unsupportedLanguage(language.isAuto ? "auto" : language.code)
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        // A language used for the first time downloads its assets; macOS shows its own progress.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        else { throw VoiceTranscriptionError.speechUnavailable("Apple Speech has no audio format.") }
        let buffer = try Self.buffer(audio, in: format)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (inputs, builder) = AsyncStream.makeStream(of: AnalyzerInput.self)
        builder.yield(AnalyzerInput(buffer: buffer))
        builder.finish()
        let collect = Task {
            var text = ""
            for try await result in transcriber.results where result.isFinal {
                text += String(result.text.characters)
            }
            return text
        }
        if let last = try await analyzer.analyzeSequence(inputs) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collect.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Resamples the 16 kHz capture into whatever format the analyzer asked for.
    private static func buffer(_ audio: VoiceAudio, in format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard
            let source = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: Double(VoiceAudio.sampleRate),
                channels: 1, interleaved: false),
            let input = AVAudioPCMBuffer(
                pcmFormat: source, frameCapacity: AVAudioFrameCount(audio.samples.count))
        else { throw VoiceTranscriptionError.speechUnavailable("Could not stage the recording.") }
        input.frameLength = AVAudioFrameCount(audio.samples.count)
        audio.samples.withUnsafeBufferPointer { samples in
            input.floatChannelData![0].update(from: samples.baseAddress!, count: samples.count)
        }
        guard format != source else { return input }
        guard let converter = AVAudioConverter(from: source, to: format) else {
            throw VoiceTranscriptionError.speechUnavailable("Could not convert the recording.")
        }
        let ratio = format.sampleRate / source.sampleRate
        let capacity = AVAudioFrameCount(Double(audio.samples.count) * ratio) + 1_024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw VoiceTranscriptionError.speechUnavailable("Could not convert the recording.")
        }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        return output
    }
}
