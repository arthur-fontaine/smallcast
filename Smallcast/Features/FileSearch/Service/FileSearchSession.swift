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
    /// DigUp is still out for the current query: names land in milliseconds, contents after them.
    private(set) var isSearchingContent = false
    /// The published search: the filter belongs to it, so narrowing re-runs the same words.
    private var request: Request?
    private var revision = 0
    @ObservationIgnored private var pending: (request: Request, revision: Int)?
    @ObservationIgnored private var workerTask: Task<Void, Never>?
    @ObservationIgnored private let searchOperation: SearchOperation
    /// Kept across closes, so the blank screen opens on its rows instead of on nothing.
    @ObservationIgnored private var recent: [FileSearchResult]?
    /// The current query's two halves; nil names have not arrived yet.
    @ObservationIgnored private var names: [FileSearchResult]?
    @ObservationIgnored private var content = DigUpMatches()
    @ObservationIgnored private var contentTask: Task<Void, Never>?
    @ObservationIgnored private var graceTask: Task<Void, Never>?
    @ObservationIgnored private var publishedRevision: Int?
    /// Rows changed under the same query as DigUp's arrived, so the selection can follow its file.
    @ObservationIgnored var onRepublish: ((_ old: [FileSearchResult], _ new: [FileSearchResult]) -> Void)?

    /// DigUp's matches ahead of the index's while set: the Name and content engine.
    @ObservationIgnored var digUp: DigUpSearch? {
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
        enqueue(request, askingDigUp: true)
        guard request == .recent, let recent else { return }
        results = recent
        state = .ready
    }

    /// With no request open, the blank screen's rows are prepared for the next open instead.
    func refresh() {
        if let request {
            // The disk changed, not DigUp's index: only the names are asked again.
            enqueue(request, askingDigUp: false)
        } else {
            Task { [weak self, searchOperation] in
                let found = await searchOperation(Request.recent.query, Request.recent.filter)
                self?.recent = found
            }
        }
    }

    func cancel() {
        revision &+= 1
        pending = nil
        request = nil
        stopContent()
        names = nil
        results = []
        state = .idle
    }

    /// A trashed row names a file that is gone, so it leaves the published results with it.
    func remove(_ result: FileSearchResult) {
        results.removeAll { $0.id == result.id }
        recent?.removeAll { $0.id == result.id }
        names?.removeAll { $0.id == result.id }
        content.strong.removeAll { $0.id == result.id }
        content.weak.removeAll { $0.id == result.id }
    }

    private func enqueue(_ request: Request, askingDigUp: Bool) {
        revision &+= 1
        self.request = request
        state = .searching
        pending = (request, revision)
        if askingDigUp {
            stopContent()
            names = nil
            if let digUp, !request.query.isEmpty { startContent(request, digUp: digUp) }
        }
        guard workerTask == nil else { return }
        workerTask = Task { [weak self] in
            await self?.runWorker()
        }
    }

    private func runWorker() async {
        while let next = pending {
            pending = nil
            let found = await searchOperation(next.request.query, next.request.filter)
            if next.request == .recent { recent = found }
            guard revision == next.revision, request == next.request else { continue }
            names = found
            namesArrived()
        }
        workerTask = nil
    }

    /// DigUp usually answers within the grace, and then the list is drawn once with both halves.
    private func namesArrived() {
        guard isSearchingContent, content.isEmpty else { return publish() }
        guard graceTask == nil else { return }
        graceTask = Task { [weak self] in
            try? await Task.sleep(for: DigUpSearchPolicy.contentGrace)
            guard !Task.isCancelled, let self else { return }
            graceTask = nil
            publish()
        }
    }

    private func startContent(_ request: Request, digUp: DigUpSearch) {
        isSearchingContent = true
        contentTask = Task { [weak self] in
            for meaning in digUp.passes {
                let found = try? await digUp.results(
                    for: request.query, filter: request.filter, meaning: meaning)
                guard !Task.isCancelled, let self else { return }
                // A failing DigUp still leaves the name search it adds to.
                guard let found else { break }
                content = found
                contentArrived()
            }
            guard !Task.isCancelled, let self else { return }
            isSearchingContent = false
            contentArrived()
        }
    }

    private func contentArrived() {
        graceTask?.cancel()
        graceTask = nil
        publish()
    }

    private func stopContent() {
        contentTask?.cancel()
        contentTask = nil
        graceTask?.cancel()
        graceTask = nil
        content = DigUpMatches()
        if isSearchingContent { isSearchingContent = false }
    }

    private func publish() {
        guard let names else { return }
        let merged = DigUpSearchPolicy.merged(content: content, names: names)
        let old = results
        if old != merged { results = merged }
        state = .ready
        let republished = publishedRevision == revision
        publishedRevision = revision
        if republished, old != merged { onRepublish?(old, merged) }
    }
}
