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

    nonisolated private static func locate(environment: [String: String]) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var candidates = [home.appending(path: ".lmstudio/bin/lms")]
        candidates += (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appending(path: "lms") }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// A watchdog bounds a wedged binary, so choosing the preset can never hang the pane.
    nonisolated private static func ask(_ executable: URL) async -> LMStudioServerStatus? {
        await Task.detached {
            let process = Process()
            process.executableURL = executable
            process.arguments = ["server", "status", "--json"]
            process.standardInput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let stdout = Pipe()
            process.standardOutput = stdout
            do { try process.run() } catch { return nil }
            let watchdog = Task {
                try await Task.sleep(for: .seconds(2))
                if process.isRunning { process.terminate() }
            }
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            watchdog.cancel()
            guard process.terminationStatus == 0 else { return nil }
            return LMStudioServerStatus.decode(data)
        }.value
    }
}
