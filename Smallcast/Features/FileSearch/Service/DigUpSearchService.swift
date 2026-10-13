import Foundation

/// `digup search-service`, kept warm: a search costs milliseconds, not a launch and a model load.
@MainActor
final class DigUpSearchService {
    enum Failure: Error, Equatable {
        case notRunning
        case ended
        case refused(String)
    }

    struct Launch: Equatable {
        let helper: URL
        let indexDirectory: String?
        let modelsDirectory: String?
    }

    let launch: Launch
    /// Whether a meaning search answers now, or first waits for the model to load.
    private(set) var isEncoderReady = false
    /// Ended before it said it was ready: a helper older than DigUp 0.6.1 has no search service.
    private(set) var isUnsupported = false
    /// DigUp's own folder choice, which its app hands its searcher the same way.
    var folders: DigUpFolders {
        didSet {
            guard folders != oldValue, input != nil else { return }
            send(
                DigUpServiceRequest(
                    id: takeID(), op: "folders", roots: folders.roots, skipped: folders.skipped,
                    types: folders.types))
        }
    }

    private var process: Process?
    private var input: FileHandle?
    private var outputBuffer = Data()
    private var isReady = false
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<DigUpServiceMessage, any Error>] = [:]

    /// An unterminated line this long is not the service talking.
    private static let outputLimit = 16 * 1_048_576

    init(launch: Launch, folders: DigUpFolders) {
        self.launch = launch
        self.folders = folders
    }

    func search(
        _ query: String, filter: FileSearchFilter, limit: Int, meaning: Bool
    ) async throws -> DigUpServiceMessage {
        try Task.checkCancellation()
        let id = takeID()
        guard
            let request = DigUpSearchPolicy.searchRequest(
                id: id, query: query, filter: filter, limit: limit, meaning: meaning)
        else { return DigUpServiceMessage(hits: []) }
        let reply = try await ask(request)
        if let error = reply.error { throw Failure.refused(error) }
        return reply
    }

    /// The File Search screen opening: the model loads while the first word is typed.
    func prewarm() {
        guard start() else { return }
        send(DigUpServiceRequest(id: takeID(), op: "prewarm"))
    }

    /// DigUp's app indexed since the service opened the index, so its vectors are stale.
    func reload() {
        guard input != nil else { return }
        send(DigUpServiceRequest(id: takeID(), op: "reload"))
    }

    /// Closing stdin is the clean exit, since the service leaves on EOF; SIGTERM is the backstop.
    func stop() {
        guard let process else { return }
        process.terminationHandler = nil
        end(with: Failure.notRunning)
        Task.detached {
            try? await Task.sleep(for: .seconds(1))
            if process.isRunning { process.terminate() }
        }
    }

    private func ask(_ request: DigUpServiceRequest) async throws -> DigUpServiceMessage {
        guard start() else { throw Failure.notRunning }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[request.id] = continuation
                send(request)
            }
        } onCancel: { [weak self] in
            Task { @MainActor in self?.finish(request.id, with: .failure(CancellationError())) }
        }
    }

    private func takeID() -> Int {
        nextID += 1
        return nextID
    }

    /// False once the helper has shown it cannot serve; after a crash, the next ask relaunches it.
    private func start() -> Bool {
        if input != nil { return true }
        guard !isUnsupported else { return false }
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        process.executableURL = launch.helper
        process.arguments = DigUpSearchPolicy.serviceArguments(
            folders: folders, indexDirectory: launch.indexDirectory)
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.environment = ExecutableLocator.environment(
            running: launch.helper,
            adding: launch.modelsDirectory.map { ["DIGUP_MODELS": $0] } ?? [:])
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.consume(data) }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.didExit() }
        }
        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            isUnsupported = true
            return false
        }
        // A service that dies mid-write must fail the write, not SIGPIPE Smallcast.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        self.process = process
        input = stdin.fileHandleForWriting
        return true
    }

    private func send(_ request: DigUpServiceRequest) {
        do {
            try input?.write(contentsOf: Data((request.line() + "\n").utf8))
        } catch {
            finish(request.id, with: .failure(Failure.ended))
        }
    }

    private func consume(_ data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = String(decoding: outputBuffer[..<newline], as: UTF8.self)
            outputBuffer.removeSubrange(...newline)
            if let message = DigUpSearchPolicy.message(fromLine: line) { handle(message) }
        }
        if outputBuffer.count > Self.outputLimit { stop() }
    }

    private func handle(_ message: DigUpServiceMessage) {
        if let encoder = message.encoder ?? (message.event == "encoder" ? message.state : nil) {
            isEncoderReady = encoder == "ready"
        }
        if message.event == "ready" { isReady = true }
        guard let id = message.id else { return }
        finish(id, with: .success(message))
    }

    private func finish(_ id: Int, with result: Result<DigUpServiceMessage, any Error>) {
        pending.removeValue(forKey: id)?.resume(with: result)
    }

    private func didExit() {
        if !isReady { isUnsupported = true }
        end(with: Failure.ended)
    }

    private func end(with error: any Error) {
        process?.terminationHandler = nil
        (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        try? input?.close()
        process = nil
        input = nil
        isReady = false
        isEncoderReady = false
        outputBuffer.removeAll(keepingCapacity: false)
        let requests = pending
        pending.removeAll()
        for continuation in requests.values { continuation.resume(throwing: error) }
    }
}

/// A list's way to DigUp: the one shared service, this list's limit and File Search's own scopes.
struct DigUpSearch: Equatable {
    let service: DigUpSearchService
    let limit: Int
    let policy: FileSearchPolicy

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.service === rhs.service && lhs.limit == rhs.limit && lhs.policy == rhs.policy
    }

    /// Keyword hits first while the model loads, so a cold search still answers at once.
    @MainActor
    var passes: [Bool] { service.isEncoderReady ? [true] : [false, true] }

    @MainActor
    func results(
        for query: String, filter: FileSearchFilter, meaning: Bool
    ) async throws -> DigUpMatches {
        let reply = try await service.search(query, filter: filter, limit: limit, meaning: meaning)
        return DigUpSearchPolicy.matches(from: reply.hits ?? [], strong: reply.strong, policy: policy)
    }
}
