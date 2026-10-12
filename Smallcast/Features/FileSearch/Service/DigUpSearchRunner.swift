import Foundation

/// One `digup search` per query: the helper loads its text model, answers in JSON and exits.
struct DigUpSearchRunner: Equatable, Sendable {
    let helper: URL
    let indexDirectory: String?
    let modelsDirectory: String?
    let limit: Int

    struct Failure: Error, Equatable {
        let status: Int32
    }

    /// Cancelling the calling task terminates the helper, so a stale query never finishes its run.
    nonisolated func results(
        for query: String, filter: FileSearchFilter, homeDirectory: URL
    ) async throws -> [FileSearchResult] {
        guard
            let arguments = DigUpSearchPolicy.arguments(
                query: query, limit: limit, filter: filter, indexDirectory: indexDirectory)
        else { return [] }
        let environment = ExecutableLocator.environment(
            running: helper, adding: modelsDirectory.map { ["DIGUP_MODELS": $0] } ?? [:])
        // The first query after a reboot reads the model from disk, so the watchdog is generous.
        let run = await InstalledAIProbe.run(
            executable: helper, arguments: arguments, workspace: homeDirectory,
            environment: environment, timeout: .seconds(30))
        try Task.checkCancellation()
        guard run.status == 0 else { throw Failure(status: run.status) }
        let hits = try DigUpSearchPolicy.hits(fromJSON: Data(run.output.utf8))
        return DigUpSearchPolicy.results(from: hits, homeDirectory: homeDirectory) { path in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
                return nil
            }
            return isDirectory.boolValue
        }
    }
}
