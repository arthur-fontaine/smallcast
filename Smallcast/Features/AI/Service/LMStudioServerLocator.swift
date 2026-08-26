import Foundation

/// Asks LM Studio's own CLI which port its server is configured on. `lms` ships at a fixed path
/// under the user's home, so unlike `codex` there is no version manager to chase.
enum LMStudioServerLocator {
    nonisolated static func status(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async -> LMStudioServerStatus? {
        guard let executable = locate(environment: environment) else { return nil }
        return await ask(executable)
    }

    /// Starts the server and reports where it landed. `lms` blocks until it is up, so the status
    /// read afterwards is the settled one rather than a guess.
    nonisolated static func start(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async -> LMStudioServerStatus? {
        guard let executable = locate(environment: environment) else { return nil }
        // Ten seconds, not two: a warm start is instant, but bootstrapping the background service
        // the first time is not.
        guard await run(executable, ["server", "start"], timeout: .seconds(10)) != nil else {
            return nil
        }
        return await ask(executable)
    }

    nonisolated private static func locate(environment: [String: String]) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var candidates = [home.appending(path: ".lmstudio/bin/lms")]
        candidates += (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appending(path: "lms") }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    nonisolated private static func ask(_ executable: URL) async -> LMStudioServerStatus? {
        guard let data = await run(executable, ["server", "status", "--json"], timeout: .seconds(2))
        else { return nil }
        return LMStudioServerStatus.decode(data)
    }

    /// A watchdog bounds a wedged binary, so nothing here can hang the pane. Nil for a kill or a
    /// non-zero exit, which is also how an `lms` too old for a flag falls through.
    nonisolated private static func run(
        _ executable: URL, _ arguments: [String], timeout: Duration
    ) async -> Data? {
        await Task.detached {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let stdout = Pipe()
            process.standardOutput = stdout
            do { try process.run() } catch { return nil }
            let watchdog = Task {
                try await Task.sleep(for: timeout)
                if process.isRunning { process.terminate() }
            }
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            watchdog.cancel()
            return process.terminationStatus == 0 ? data : nil
        }.value
    }
}
