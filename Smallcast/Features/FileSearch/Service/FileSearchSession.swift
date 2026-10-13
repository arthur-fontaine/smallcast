import Foundation

@MainActor
@Observable
final class FileSearchSession {
    typealias SearchOperation = @Sendable (String, FileSearchFilter) async -> [FileSearchResult]

    enum State: Equatable {
        case idle
        case searching
        case ready
    }

    private(set) var results: [FileSearchResult] = []
    private(set) var state: State = .idle
    /// The published search: the filter belongs to it, so narrowing re-runs the same words.
    private var request: Request?
    private var revision = 0
    @ObservationIgnored private var pending: (request: Request, revision: Int)?
    @ObservationIgnored private var workerTask: Task<Void, Never>?
    @ObservationIgnored private let searchOperation: SearchOperation
    /// Kept across closes, so the blank screen opens on its rows instead of on nothing.
    @ObservationIgnored private var recent: [FileSearchResult]?
    @ObservationIgnored private let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
    @ObservationIgnored private var digUpRun: Task<[FileSearchResult], Never>?

    /// DigUp's matches ahead of the index's while set: the Name and content engine.
    @ObservationIgnored var digUp: DigUpSearchRunner? {
        didSet { if digUp != oldValue { cancel() } }
    }

    private struct Request: Equatable {
        static let recent = Request(query: "", filter: .all)

        let query: String
        let filter: FileSearchFilter
    }

    /// No debounce: a search costs milliseconds, and the worker already runs only the newest.
    init(index: FileIndex) {
        searchOperation = { query, filter in
            await Task.detached(priority: .userInitiated) {
                guard let prepared = FileSearchQuery.prepare(query) else {
                    return index.recent(filter: filter)
                }
                return index.search(prepared, filter: filter)
            }.value
        }
    }

    init(searchOperation: @escaping SearchOperation) {
        self.searchOperation = searchOperation
    }

    /// An empty query is a request too: the blank screen lists what changed recently.
    func search(_ rawQuery: String, filter: FileSearchFilter = .all) {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = Request(query: query, filter: filter)
        guard request != self.request else { return }
        enqueue(request)
        guard request == .recent, let recent else { return }
        results = recent
        state = .ready
    }

    /// With no request open, the blank screen's rows are prepared for the next open instead.
    func refresh() {
        if let request {
            enqueue(request)
        } else {
            Task { [weak self, searchOperation] in
                let found = await searchOperation(Request.recent.query, Request.recent.filter)
                self?.recent = found
            }
        }
    }

    func cancel() {
        digUpRun?.cancel()
        revision &+= 1
        pending = nil
        request = nil
        results = []
        state = .idle
    }

    /// A trashed row names a file that is gone, so it leaves the published results with it.
    func remove(_ result: FileSearchResult) {
        results.removeAll { $0.id == result.id }
        recent?.removeAll { $0.id == result.id }
    }

    private func enqueue(_ request: Request) {
        digUpRun?.cancel()
        revision &+= 1
        self.request = request
        state = .searching
        pending = (request, revision)
        guard workerTask == nil else { return }
        workerTask = Task { [weak self] in
            await self?.runWorker()
        }
    }

    private func runWorker() async {
        while let next = pending {
            pending = nil
            let found = await search(next.request)
            if next.request == .recent { recent = found }
            guard revision == next.revision, request == next.request else { continue }
            if results != found { results = found }
            state = .ready
        }
        workerTask = nil
    }

    private func search(_ request: Request) async -> [FileSearchResult] {
        guard let digUp, !request.query.isEmpty else {
            return await searchOperation(request.query, request.filter)
        }
        let run = Task { [searchOperation, homeDirectory] in
            async let names = searchOperation(request.query, request.filter)
            // DigUp failing still leaves the name search it adds to.
            let content = try? await digUp.results(
                for: request.query, filter: request.filter, homeDirectory: homeDirectory)
            return DigUpSearchPolicy.merged(content: content ?? [], names: await names)
        }
        digUpRun = run
        return await run.value
    }
}
