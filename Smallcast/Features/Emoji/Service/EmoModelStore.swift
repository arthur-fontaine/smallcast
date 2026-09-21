import CryptoKit
import Foundation

/// The Emo model files on disk: fetched once from Hugging Face at a pinned revision, checked by hash.
@MainActor
@Observable
final class EmoModelStore {
    static let provider = "Desert Ant Labs"
    static let providerURL = URL(string: "https://desertant.com")!
    nonisolated static let modelURL = URL(string: "https://huggingface.co/desert-ant-labs/emo")!
    nonisolated static let revision = "v0.7.0"

    struct ModelFile: Sendable {
        let path: String
        let sha256: String
        let size: Int64
    }

    /// Every file the Core ML export needs, with the digests the pinned revision serves.
    static let files: [ModelFile] = [
        ModelFile(
            path: "emo.mlmodelc/analytics/coremldata.bin",
            sha256: "f8dd02401ec57a52856cd0681540405ed22701b9df5efe9bec9673788bda488e", size: 243),
        ModelFile(
            path: "emo.mlmodelc/coremldata.bin",
            sha256: "8fdfcb08b1af69e63edbc9f056ac5bf999f286c6b2f2163f3873b6d395fc2ede", size: 657),
        ModelFile(
            path: "emo.mlmodelc/metadata.json",
            sha256: "d8c98c6ff7e4bdf68710d08f04d16dd5f838578dd31d4ccbb68048a534e250d2", size: 3706),
        ModelFile(
            path: "emo.mlmodelc/model.mil",
            sha256: "87455cbccc4ea7ad624769ef0e1023059531db1aecf4f03a42badbaa9a31cb01", size: 60743),
        ModelFile(
            path: "emo.mlmodelc/weights/weight.bin",
            sha256: "eae49cf80a4cb1187ffedf04ebd9bf4b49aa9b99ae2a36a25b1927689c74fa80", size: 4_701_400),
        ModelFile(
            path: "emo_meta.json",
            sha256: "a3143258ac4099de65367cd4598073f1f5ce94f0eb505a30331762619967d3f6", size: 6280),
        ModelFile(
            path: "emo_tokenizer.bin",
            sha256: "f54462a7a2344f15c9430ed4e399c49444f890dd6094c745a0c5391690bf019d", size: 733_197)
    ]

    static var totalSize: Int64 { files.reduce(0) { $0 + $1.size } }

    enum Failure: LocalizedError {
        case network(String)
        case corrupt(String)

        var errorDescription: String? {
            switch self {
            case .network(let message): return "The model download failed. \(message)"
            case .corrupt(let path): return "\(path) did not match the published checksum."
            }
        }
    }

    let directory: URL
    /// 0…1 while a download runs, nil otherwise.
    private(set) var progress: Double?

    init(directory: URL = AppPaths.caches().appendingPathComponent("emo-\(revision)", isDirectory: true)) {
        self.directory = directory
    }

    var isDownloaded: Bool {
        Self.files.allSatisfy { Self.sizeOnDisk(directory.appendingPathComponent($0.path)) == $0.size }
    }

    private nonisolated static func sizeOnDisk(_ url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
    }

    /// Fetches whatever is missing, verifying each file before it lands under `directory`.
    func download() async throws {
        guard !isDownloaded else { return }
        progress = 0
        defer { progress = nil }
        var received: Int64 = 0
        for file in Self.files {
            let destination = directory.appendingPathComponent(file.path)
            if Self.sizeOnDisk(destination) != file.size {
                let data = try await Self.fetch(file)
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: destination, options: .atomic)
            }
            received += file.size
            progress = Double(received) / Double(Self.totalSize)
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Cacheless, never `URLSession.shared`, so the verified copy on disk is the only one.
    private nonisolated static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    private nonisolated static func fetch(_ file: ModelFile) async throws -> Data {
        let url = modelURL.appendingPathComponent("resolve/\(revision)/\(file.path)")
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue("Smallcast", forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw Failure.network("The server answered \((response as? HTTPURLResponse)?.statusCode ?? 0).")
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard Int64(data.count) == file.size, digest == file.sha256 else {
            throw Failure.corrupt(file.path)
        }
        return data
    }
}
