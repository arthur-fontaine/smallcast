import AVFoundation
import Foundation
import os

/// Captures the microphone while a hold lasts and hands back 16 kHz mono samples on release.
@MainActor
final class VoiceRecorder {
    private var session: AVCaptureSession?
    private let sink = SampleSink()
    private var levelTask: Task<Void, Never>?
    private(set) var isRecording = false

    /// 0…1, refreshed a few times a second while recording.
    var onLevel: ((Float) -> Void)?

    func start() throws {
        guard !isRecording else { return }
        guard let device = AVCaptureDevice.default(for: .audio) else {
            throw VoiceRecorderError.noInput
        }
        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        // The capture pipeline resamples for us, so every engine gets the one format it takes.
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: VoiceAudio.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        output.setSampleBufferDelegate(sink, queue: DispatchQueue(label: "smallcast.voice.capture"))
        guard session.canAddInput(input), session.canAddOutput(output) else {
            throw VoiceRecorderError.noInput
        }
        session.addInput(input)
        session.addOutput(output)
        sink.reset()
        self.session = session
        let box = CaptureBox(session: session)
        Task.detached { box.session.startRunning() }
        isRecording = true
        levelTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(60))
                guard let self else { return }
                onLevel?(sink.takeLevel())
            }
        }
    }

    /// Stops the microphone and hands back everything heard since `start`.
    func stop() -> VoiceAudio {
        levelTask?.cancel()
        levelTask = nil
        guard isRecording, let session else { return VoiceAudio(samples: []) }
        // The microphone indicator must go out on release, so this never waits for deallocation.
        let box = CaptureBox(session: session)
        Task.detached { box.session.stopRunning() }
        self.session = nil
        isRecording = false
        return VoiceAudio(samples: sink.drain())
    }
}

/// `AVCaptureSession` is not `Sendable`; the start and stop calls block, so they go off main.
private struct CaptureBox: @unchecked Sendable {
    let session: AVCaptureSession
}

enum VoiceRecorderError: LocalizedError {
    case noInput
    var errorDescription: String? { "No microphone is available." }
}

/// Written from the capture queue, read on main: everything crosses under one lock.
private final class SampleSink: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, Sendable {
    private struct Store {
        var samples: [Float] = []
        var peak: Float = 0
    }

    private let store = OSAllocatedUnfairLock(initialState: Store())

    func reset() {
        store.withLock { $0 = Store() }
    }

    func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let length = CMBlockBufferGetDataLength(block)
        let count = length / MemoryLayout<Float>.size
        guard count > 0 else { return }
        var chunk = [Float](repeating: 0, count: count)
        let copied = chunk.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: bytes.baseAddress!)
        }
        guard copied == kCMBlockBufferNoErr else { return }
        var peak: Float = 0
        for sample in chunk { peak = max(peak, abs(sample)) }
        let samples = chunk
        let loudest = peak
        store.withLock {
            $0.samples.append(contentsOf: samples)
            $0.peak = max($0.peak, loudest)
        }
    }

    /// The loudest sample since the last read, squashed so quiet speech still moves the meter.
    func takeLevel() -> Float {
        let peak = store.withLock { state -> Float in
            defer { state.peak = 0 }
            return state.peak
        }
        guard peak > 0 else { return 0 }
        let decibels = 20 * log10(peak)
        return max(0, min(1, (decibels + 50) / 50))
    }

    func drain() -> [Float] {
        store.withLock { state in
            defer { state = Store() }
            return state.samples
        }
    }
}
