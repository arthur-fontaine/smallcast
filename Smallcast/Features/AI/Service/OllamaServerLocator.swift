import Foundation

/// Where Ollama is listening. It publishes no status command, so the only thing to read is the
/// `OLLAMA_HOST` its own FAQ tells macOS users to set — and `launchctl setenv` reaches processes
/// started after it, so the app's inherited copy can be stale or absent.
enum OllamaServerLocator {
    nonisolated static func host(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async -> OllamaHost? {
        if let inherited = environment["OLLAMA_HOST"].flatMap(OllamaHost.parse) { return inherited }
        guard let value = await launchctlValue() else { return nil }
        return OllamaHost.parse(value)
    }

    /// `getenv` exits 0 with nothing at all for an unset name, so the output is the only signal.
    nonisolated private static func launchctlValue() async -> String? {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["getenv", "OLLAMA_HOST"]
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
            let value = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }.value
    }
}
