import Foundation

/// DigUp as File Search sees it: here, set up, and the one search service both lists share.
@MainActor
@Observable
final class DigUpState {
    private(set) var availability: DigUpLocator.Availability = .notInstalled
    private(set) var isSetUp = false
    /// DigUp's roots that File Search's scopes reach; empty means content search finds nothing.
    private(set) var reachableRoots: [String] = []
    private(set) var folders = DigUpFolders()
    @ObservationIgnored private var service: DigUpSearchService?
    @ObservationIgnored private var isEnabled = false
    @ObservationIgnored private var policy: FileSearchPolicy?
    @ObservationIgnored private var indexModified: Date?

    var helper: URL? {
        guard case .found(let url) = availability else { return nil }
        return url
    }

    /// The service ended before it could answer: DigUp older than 0.6.1, or its index unreadable.
    var serviceFailed: Bool { service?.isUnsupported == true }

    func refresh(customPath: String) {
        let availability = DigUpLocator.locate(customPath: customPath)
        if availability != self.availability { self.availability = availability }
        let isSetUp = DigUpLocator.isSetUp()
        if isSetUp != self.isSetUp { self.isSetUp = isSetUp }
        let folders = DigUpLocator.folders()
        if folders != self.folders { self.folders = folders }
        updateReachableRoots()
        let directories = DigUpLocator.dataDirectories()
        let launch = helper.map {
            DigUpSearchService.Launch(
                helper: $0, indexDirectory: directories.index, modelsDirectory: directories.models)
        }
        guard isEnabled, let launch else { return stopService() }
        if let service, service.launch == launch, !service.isUnsupported {
            service.folders = folders
        } else {
            service?.stop()
            service = DigUpSearchService(launch: launch, folders: folders)
            indexModified = DigUpLocator.indexModified(indexDirectory: launch.indexDirectory)
        }
    }

    /// The Name and content engine with File Search on; anything else stops the service.
    func setEnabled(_ enabled: Bool, customPath: String) {
        isEnabled = enabled
        refresh(customPath: customPath)
    }

    func apply(_ policy: FileSearchPolicy) {
        self.policy = policy
        updateReachableRoots()
    }

    /// Nil when nothing should ask DigUp: switched off, or no helper to run.
    func search(limit: Int) -> DigUpSearch? {
        guard let service, let policy, !service.isUnsupported else { return nil }
        return DigUpSearch(service: service, limit: limit, policy: policy)
    }

    /// Before a search screen opens: catch up with DigUp's indexing, and start the model loading.
    func prepare(prewarming: Bool) {
        guard let service else { return }
        let modified = DigUpLocator.indexModified(indexDirectory: service.launch.indexDirectory)
        if modified != indexModified {
            indexModified = modified
            service.reload()
        }
        if prewarming { service.prewarm() }
    }

    private func stopService() {
        service?.stop()
        service = nil
    }

    private func updateReachableRoots() {
        let reachable = policy.map { DigUpSearchPolicy.reachableRoots(folders, policy: $0) } ?? []
        if reachable != reachableRoots { reachableRoots = reachable }
    }
}
