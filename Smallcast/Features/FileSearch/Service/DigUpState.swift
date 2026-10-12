import Foundation

/// Whether DigUp is on this Mac and set up, re-read when Settings opens or the typed path changes.
@MainActor
@Observable
final class DigUpState {
    private(set) var availability: DigUpLocator.Availability = .notInstalled
    private(set) var isSetUp = false
    @ObservationIgnored private var dataDirectories: (index: String?, models: String?) = (nil, nil)

    var helper: URL? {
        guard case .found(let url) = availability else { return nil }
        return url
    }

    func refresh(customPath: String) {
        let availability = DigUpLocator.locate(customPath: customPath)
        if availability != self.availability { self.availability = availability }
        dataDirectories = DigUpLocator.dataDirectories()
        let isSetUp = DigUpLocator.isSetUp()
        if isSetUp != self.isSetUp { self.isSetUp = isSetUp }
    }

    /// Nil when nothing should ask DigUp: switched off, or no helper to run.
    func runner(limit: Int, enabled: Bool) -> DigUpSearchRunner? {
        guard enabled, let helper else { return nil }
        return DigUpSearchRunner(
            helper: helper, indexDirectory: dataDirectories.index,
            modelsDirectory: dataDirectories.models, limit: limit)
    }
}
