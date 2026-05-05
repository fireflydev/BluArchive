import Foundation

/// Runs CLI tools with streamed stdout/stderr and cooperative cancellation.
final class ProcessRunner: @unchecked Sendable {
    struct RunError: LocalizedError {
        let command: String
        let exitCode: Int32
        let combinedOutput: String

        var errorDescription: String? {
            "Command failed (\(exitCode)): \(command)\n\(combinedOutput)"
        }
    }

    private let processQueue = DispatchQueue(label: "BDXLBackupApp.ProcessRunner")
    private var currentProcess: Process?

    nonisolated init() {}

    func cancel() {
        processQueue.sync {
            currentProcess?.terminate()
            currentProcess = nil
        }
    }

    /// Runs process; invokes `onLine` on the main actor for each output line.
    @MainActor
    func runStreaming(
        launchPath: String,
        arguments: [String],
        currentDirectory: URL? = nil,
        environment: [String: String]? = nil,
        onLine: @escaping @MainActor (String) -> Void
    ) async throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory

        if let environment {
            var env = ProcessInfo.processInfo.environment
            for (k, v) in environment {
                env[k] = v
            }
            process.environment = env
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        processQueue.sync {
            currentProcess = process
        }

        defer {
            processQueue.sync {
                if currentProcess === process {
                    currentProcess = nil
                }
            }
        }

        try process.run()

        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading

        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                do {
                    try await Self.consumeLines(from: outHandle, onLine: onLine)
                } catch {
                    onLine("[stdout read error] \(error.localizedDescription)")
                }
            }
            group.addTask { @MainActor in
                do {
                    try await Self.consumeLines(from: errHandle, onLine: onLine)
                } catch {
                    onLine("[stderr read error] \(error.localizedDescription)")
                }
            }
            group.addTask {
                process.waitUntilExit()
            }
        }

        return process.terminationStatus
    }

    /// Non-streaming run (tests / small output).
    func runCollecting(
        launchPath: String,
        arguments: [String],
        currentDirectory: URL? = nil
    ) async throws -> (exitCode: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        return (process.terminationStatus, text)
    }

    @MainActor
    private static func consumeLines(
        from handle: FileHandle,
        onLine: @escaping @MainActor (String) -> Void
    ) async throws {
        for try await rawLine in handle.bytes.lines {
            if Task.isCancelled { break }
            let line = String(rawLine)
            onLine(line)
        }
    }
}

enum ToolResolver {
    /// PATH used when resolving `which`.
    static var enrichedPATH: String {
        let homebrew = "/opt/homebrew/bin:/usr/local/bin"
        let existing = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        return "\(homebrew):\(existing)"
    }

    static func par2Executable() async -> String? {
        let candidates = [
            "/opt/homebrew/bin/par2",
            "/usr/local/bin/par2"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        do {
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = enrichedPATH
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["bash", "-lc", "which par2"]
            process.environment = env
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let trimmed = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if process.terminationStatus == 0,
               !trimmed.isEmpty,
               FileManager.default.isExecutableFile(atPath: trimmed) {
                return trimmed
            }
        } catch {
            return nil
        }
        return nil
    }

    static func shasumExecutable() -> String {
        "/usr/bin/shasum"
    }

    static func tarExecutable() -> String {
        "/usr/bin/tar"
    }

    static func hdiutilExecutable() -> String {
        resolveExecutable(
            named: "hdiutil",
            preferred: ["/usr/bin/hdiutil", "/usr/sbin/hdiutil"],
            defaultPath: "/usr/bin/hdiutil"
        )
    }

    static func drutilExecutable() -> String {
        "/usr/bin/drutil"
    }

    static func diskutilExecutable() -> String {
        resolveExecutable(
            named: "diskutil",
            preferred: ["/usr/sbin/diskutil", "/sbin/diskutil"],
            defaultPath: "/usr/sbin/diskutil"
        )
    }

    static func duExecutable() -> String {
        "/usr/bin/du"
    }

    private static func resolveExecutable(
        named name: String,
        preferred: [String],
        defaultPath: String
    ) -> String {
        if let direct = firstExecutable(from: preferred) {
            return direct
        }
        if let fromPATH = executableInPATH(named: name) {
            return fromPATH
        }
        return defaultPath
    }

    private static func firstExecutable(from paths: [String]) -> String? {
        for path in paths where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    private static func executableInPATH(named name: String) -> String? {
        let pathValue = enrichedPATH
        for directory in pathValue.split(separator: ":") {
            let candidate = String(directory) + "/" + name
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
