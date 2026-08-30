import Foundation

struct ShellResult: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String

    var succeeded: Bool { exitCode == 0 }
    var combined: String {
        [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

enum ShellEvent: Sendable {
    /// `overwritesPrevious` carries terminal \r semantics: the line replaces the
    /// previously emitted line (curl/brew progress bars redraw in place).
    case output(line: String, isError: Bool, overwritesPrevious: Bool)
    case finished(Int32)
}

struct ShellHandle {
    let process: Process
    let events: AsyncStream<ShellEvent>

    func terminate() {
        if process.isRunning { process.terminate() }
    }
}

enum Shell {

    /// Launches a process and streams its output line by line.
    static func launch(
        _ executablePath: String,
        _ arguments: [String],
        extraEnvironment: [String: String] = [:]
    ) -> ShellHandle {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        var environment = ProcessInfo.processInfo.environment
        let brewBin = BrewEnvironment.current.binDir
        let basePath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        if !basePath.contains(brewBin) {
            environment["PATH"] = brewBin + ":" + basePath
        }
        environment["NO_COLOR"] = "1"
        environment["TERM"] = "dumb"
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        environment["HOMEBREW_NO_EMOJI"] = "1"
        // Let sudo-needing children (mas, pkg installers) prompt via the native
        // macOS dialog instead of failing with "a terminal is required".
        if environment["SUDO_ASKPASS"] == nil, let askpass = AskPass.ensureInstalled() {
            environment["SUDO_ASKPASS"] = askpass
        }
        for (key, value) in extraEnvironment { environment[key] = value }
        process.environment = environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        let events = AsyncStream<ShellEvent> { continuation in
            do {
                try process.run()
            } catch {
                continuation.yield(.output(line: "Failed to launch \(executablePath): \(error.localizedDescription)", isError: true, overwritesPrevious: false))
                continuation.yield(.finished(-1))
                continuation.finish()
                return
            }

            // Read both pipes with plain blocking reads on GCD.
            // (FileHandle.bytes.lines deadlocks when two pipes are drained
            // concurrently and the output is large, so we roll our own.)
            let group = DispatchGroup()
            group.enter()
            pump(outPipe.fileHandleForReading, isError: false, into: continuation) { group.leave() }
            group.enter()
            pump(errPipe.fileHandleForReading, isError: true, into: continuation) { group.leave() }

            group.notify(queue: .global(qos: .userInitiated)) {
                process.waitUntilExit()
                continuation.yield(.finished(process.terminationStatus))
                continuation.finish()
            }
        }
        return ShellHandle(process: process, events: events)
    }

    /// Blocking line reader on a background queue. Splits incoming chunks on
    /// \n AND \r in O(n), carrying partial lines (a 1 MB single-line JSON payload
    /// arrives as one line at EOF). A segment terminated by \r marks the NEXT
    /// segment as overwriting it, so progress bars redraw instead of flooding.
    private static func pump(
        _ handle: FileHandle,
        isError: Bool,
        into continuation: AsyncStream<ShellEvent>.Continuation,
        completion: @escaping () -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            var carry = Data()
            var nextOverwrites = false
            func emit(_ data: Data, terminator: UInt8?) {
                let line = String(decoding: data, as: UTF8.self).strippingANSICodes
                // Skip the empty segment of a "\r\n" pair.
                if line.isEmpty && terminator == 0x0A && nextOverwrites {
                    nextOverwrites = false
                    return
                }
                continuation.yield(.output(line: line, isError: isError, overwritesPrevious: nextOverwrites))
                nextOverwrites = terminator == 0x0D
            }
            while true {
                let data = handle.availableData
                if data.isEmpty { break } // EOF
                var start = data.startIndex
                for index in data.indices where data[index] == 0x0A || data[index] == 0x0D {
                    if carry.isEmpty {
                        emit(data.subdata(in: start..<index), terminator: data[index])
                    } else {
                        carry.append(data.subdata(in: start..<index))
                        emit(carry, terminator: data[index])
                        carry.removeAll(keepingCapacity: true)
                    }
                    start = data.index(after: index)
                }
                if start < data.endIndex {
                    carry.append(data.subdata(in: start..<data.endIndex))
                }
            }
            if !carry.isEmpty { emit(carry, terminator: nil) }
            try? handle.close()
            completion()
        }
    }

    /// Runs a process to completion and captures its output.
    static func run(
        _ executablePath: String,
        _ arguments: [String],
        extraEnvironment: [String: String] = [:]
    ) async -> ShellResult {
        let handle = launch(executablePath, arguments, extraEnvironment: extraEnvironment)
        var out: [String] = []
        var err: [String] = []
        var code: Int32 = -1
        for await event in handle.events {
            switch event {
            case .output(let line, let isError, let overwrites):
                if isError {
                    if overwrites && !err.isEmpty { err[err.count - 1] = line } else { err.append(line) }
                } else {
                    if overwrites && !out.isEmpty { out[out.count - 1] = line } else { out.append(line) }
                }
            case .finished(let exitCode):
                code = exitCode
            }
        }
        return ShellResult(exitCode: code, stdout: out.joined(separator: "\n"), stderr: err.joined(separator: "\n"))
    }

    /// Runs `brew` with sensible defaults for background/read-only usage.
    static func runBrew(
        _ arguments: [String],
        extraEnvironment: [String: String] = [:]
    ) async -> ShellResult {
        var env = extraEnvironment
        if arguments.first != "update" && env["HOMEBREW_NO_AUTO_UPDATE"] == nil {
            env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        }
        return await run(BrewEnvironment.current.brewPath, arguments, extraEnvironment: env)
    }
}

/// Runs async closures strictly one after another (Homebrew holds a global lock,
/// so mutating commands must never overlap).
final actor SerialQueue {
    private var lastTask: Task<Void, Never>?

    func enqueue<T: Sendable>(_ operation: @escaping @Sendable () async -> T) async -> T {
        let previous = lastTask
        let task = Task<T, Never> {
            await previous?.value
            return await operation()
        }
        lastTask = Task { _ = await task.value }
        return await task.value
    }
}

extension String {
    var strippingANSICodes: String {
        guard contains("\u{001B}") || contains("\r") else { return self }
        var result = replacingOccurrences(
            of: "\u{001B}\\[[0-9;?]*[A-Za-z]",
            with: "",
            options: .regularExpression
        )
        // Keep only the final state of carriage-return progress lines.
        if let lastCR = result.lastIndex(of: "\r") {
            result = String(result[result.index(after: lastCR)...])
        }
        return result
    }
}
