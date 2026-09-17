import Foundation

/// Where an engine's files stand on this Mac: absent, arriving, ready, or refused.
enum VoiceModelStatus: Equatable, Sendable {
    case notInstalled
    case downloading(Double)
    case installed
    case failed(String)

    var isInstalled: Bool { self == .installed }
    var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }
}

/// Downloads and keeps speech models. Fetches only what the user picks, on a cacheless session.
@MainActor
@Observable
final class VoiceModelStore {
    private(set) var statuses: [VoiceEngine: VoiceModelStatus] = [:]
    @ObservationIgnored private var downloads: [VoiceEngine: Task<Void, Never>] = [:]
    let root: URL

    init(root: URL = AppPaths.applicationSupport().appendingPathComponent("voice-models", isDirectory: true)) {
        self.root = root
        for engine in VoiceEngine.allCases {
            statuses[engine] = Self.isInstalled(engine, root: root) ? .installed : .notInstalled
        }
    }

    func status(for engine: VoiceEngine) -> VoiceModelStatus {
        // The built-in engine is always present; there is nothing to fetch for it.
        engine.assets == nil ? .installed : statuses[engine] ?? .notInstalled
    }

    /// Every file for `engine` lives under its repo, so two engines sharing a repo share files.
    func directory(for engine: VoiceEngine) -> URL {
        root.appendingPathComponent(engine.assets?.repo ?? "system", isDirectory: true)
    }

    func install(_ engine: VoiceEngine) {
        guard let assets = engine.assets, downloads[engine] == nil, status(for: engine) != .installed
        else { return }
        statuses[engine] = .downloading(0)
        let root = self.root
        let expected = engine.downloadBytes ?? 0
        downloads[engine] = Task {
            do {
                try await VoiceModelDownloader.fetch(assets, into: root, expectedBytes: expected) {
                    progress in
                    Task { @MainActor in self.noteProgress(progress, for: engine) }
                }
                statuses[engine] = .installed
            } catch is CancellationError {
                statuses[engine] = .notInstalled
            } catch {
                statuses[engine] = .failed(error.localizedDescription)
            }
            downloads[engine] = nil
        }
    }

    private func noteProgress(_ progress: Double, for engine: VoiceEngine) {
        guard downloads[engine] != nil else { return }
        statuses[engine] = .downloading(progress)
    }

    func cancelInstall(_ engine: VoiceEngine) {
        downloads[engine]?.cancel()
    }

    /// Deletes the engine's files; a file another installed engine also lists is kept.
    func remove(_ engine: VoiceEngine) {
        guard let assets = engine.assets else { return }
        cancelInstall(engine)
        let keep = Set(
            VoiceEngine.allCases
                .filter { $0 != engine && status(for: $0) == .installed }
                .flatMap { $0.assets?.files ?? [] })
        for file in assets.files where !keep.contains(file) {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(file.repo).appendingPathComponent(file.path))
        }
        try? FileManager.default.removeItem(
            at: root.appendingPathComponent(assets.repo).appendingPathComponent("compiled"))
        statuses[engine] = .notInstalled
    }

    nonisolated private static func isInstalled(_ engine: VoiceEngine, root: URL) -> Bool {
        guard let assets = engine.assets else { return true }
        return assets.files.allSatisfy { file in
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(file.repo).appendingPathComponent(file.path).path)
        }
    }
}

/// The Hugging Face fetch: list each bundle's files, then stream every file to disk.
enum VoiceModelDownloader {
    /// Cacheless and private, so the model folder stays the only copy on disk.
    nonisolated private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 60
        return URLSession(configuration: configuration)
    }()

    nonisolated static func fetch(
        _ assets: VoiceModelAssets, into root: URL, expectedBytes: Int64,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        var files: [VoiceModelAssets.File] = []
        for file in assets.files {
            files += file.isBundle ? try await list(file) : [file]
        }
        var received: Int64 = 0
        for file in files {
            let destination = root.appendingPathComponent(file.repo).appendingPathComponent(file.path)
            if let size = try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 {
                received += Int64(size)
                continue
            }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let partial = destination.appendingPathExtension("part")
            let before = received
            received += try await download(file.url, to: partial) { bytes in
                if expectedBytes > 0 {
                    progress(min(0.99, Double(before + bytes) / Double(expectedBytes)))
                }
            }
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: partial)
        }
        progress(1)
    }

    private struct TreeEntry: Decodable {
        let type: String
        let path: String
    }

    nonisolated private static func list(_ bundle: VoiceModelAssets.File) async throws -> [VoiceModelAssets.File] {
        let (data, response) = try await session.data(from: bundle.treeURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let entries = try JSONDecoder().decode([TreeEntry].self, from: data)
        let files = entries.filter { $0.type == "file" }.map {
            VoiceModelAssets.File(repo: bundle.repo, path: $0.path)
        }
        guard !files.isEmpty else { throw URLError(.fileDoesNotExist) }
        return files
    }

    /// Streams to `destination`, reporting the running byte count; returns the file's size.
    nonisolated private static func download(
        _ url: URL, to destination: URL, onBytes: @escaping @Sendable (Int64) -> Void
    ) async throws -> Int64 {
        let (bytes, response) = try await session.bytes(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var chunk = Data()
        chunk.reserveCapacity(1 << 20)
        var written: Int64 = 0
        for try await byte in bytes {
            chunk.append(byte)
            if chunk.count >= 1 << 20 {
                try handle.write(contentsOf: chunk)
                written += Int64(chunk.count)
                onBytes(written)
                chunk.removeAll(keepingCapacity: true)
                try Task.checkCancellation()
            }
        }
        if !chunk.isEmpty {
            try handle.write(contentsOf: chunk)
            written += Int64(chunk.count)
            onBytes(written)
        }
        return written
    }
}
