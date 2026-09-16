import Foundation

/// Where the user's Codex keeps its login. `CODEX_HOME` is usually exported from a shell rc file,
/// which Finder-launched processes never read, so the app's inherited copy is the exception.
enum CodexHomeLocator {
    nonisolated static func home(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async -> String? {
        if let inherited = environment["CODEX_HOME"], !inherited.isEmpty { return inherited }
        return await loginShellValue()
    }

    /// `-i` reads the rc file the export lives in; a watchdog bounds a hang.
    nonisolated private static func loginShellValue() async -> String? {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-ilc", "printf %s \"$CODEX_HOME\""]
            process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
            process.environment = ProcessInfo.processInfo.environment.merging(["SMALLCAST": "1"]) {
                _, new in new
            }
            process.standardInput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let stdout = Pipe()
            process.standardOutput = stdout
            do { try process.run() } catch { return nil }
            let watchdog = Task {
                try await Task.sleep(for: .seconds(5))
                if process.isRunning { process.terminate() }
            }
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            watchdog.cancel()
            guard process.terminationStatus == 0 else { return nil }
            let path = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return path.hasPrefix("/") ? path : nil
        }.value
    }
}
