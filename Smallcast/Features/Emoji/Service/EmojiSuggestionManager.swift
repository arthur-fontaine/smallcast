import Foundation

/// Owns the opt-in suggestion pipeline: the typed-text record, the model files and the classifier.
@MainActor
@Observable
final class EmojiSuggestionManager {
    enum Status: Equatable, Sendable {
        case off
        case downloading
        case loading
        case ready
        case failed(String)
    }

    /// One grid row: the suggestions are a shortcut, not a second catalog.
    nonisolated static let limit = 8
    /// Below this the classifier is guessing; an empty row reads better than a random one.
    nonisolated static let minimumConfidence = 0.02

    private(set) var suggestions: [EmoSuggestion] = []
    private(set) var status: Status = .off

    let recorder: TypedTextRecorder
    let modelStore: EmoModelStore
    @ObservationIgnored private var suggester: EmoSuggester?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var suggestTask: Task<Void, Never>?
    private var isEnabled = false

    init(recorder: TypedTextRecorder, modelStore: EmoModelStore = EmoModelStore()) {
        self.recorder = recorder
        self.modelStore = modelStore
    }

    var modelProgress: Double? { modelStore.progress }

    /// Reconciles everything the switch owns; off tears down and forgets the record.
    func applyEnabled(_ enabled: Bool) {
        isEnabled = enabled
        guard enabled else {
            loadTask?.cancel()
            loadTask = nil
            suggestTask?.cancel()
            suggestTask = nil
            suggester = nil
            suggestions = []
            recorder.stop()
            status = .off
            return
        }
        recorder.start()
        loadModelIfNeeded()
    }

    /// Off also deletes the download, so the switch is the whole footprint.
    func removeModel() {
        suggester = nil
        modelStore.remove()
    }

    func retry() {
        guard isEnabled else { return }
        loadModelIfNeeded()
    }

    /// Called as the picker opens: the record at that moment is the phrase to suggest for.
    func refresh() {
        suggestTask?.cancel()
        guard isEnabled, let suggester else {
            suggestions = []
            return
        }
        let phrase = recorder.phrase
        guard !phrase.isEmpty else {
            suggestions = []
            return
        }
        suggestTask = Task { [weak self] in
            let ranked = await Task.detached(priority: .userInitiated) {
                try? suggester.suggest(
                    phrase, limit: Self.limit, minimumConfidence: Self.minimumConfidence)
            }.value
            guard let self, !Task.isCancelled else { return }
            suggestions = ranked ?? []
        }
    }

    private func loadModelIfNeeded() {
        guard suggester == nil, loadTask == nil else {
            refreshStatus()
            return
        }
        loadTask = Task { [weak self] in
            guard let self else { return }
            defer { loadTask = nil }
            do {
                if !modelStore.isDownloaded {
                    status = .downloading
                    try await modelStore.download()
                }
                status = .loading
                let directory = modelStore.directory
                suggester = try await Task.detached(priority: .utility) {
                    try EmoSuggester(directory: directory)
                }.value
                refreshStatus()
            } catch {
                guard !Task.isCancelled else { return }
                status = .failed(error.localizedDescription)
            }
        }
    }

    private func refreshStatus() {
        guard isEnabled else {
            status = .off
            return
        }
        if suggester != nil { status = .ready }
    }
}
