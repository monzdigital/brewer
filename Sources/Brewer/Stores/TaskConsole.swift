import Foundation
import Observation

/// Runs brew (and other) commands one at a time, exposing live output to the UI.
@MainActor
@Observable
final class TaskConsole {

    struct OutputLine: Identifiable {
        let id = UUID()
        let text: String
        let isError: Bool
    }

    enum OperationState: Equatable {
        case queued
        case running
        case succeeded
        case failed(Int32)
        case cancelled

        var isFinished: Bool { self != .running && self != .queued }
    }

    @Observable
    final class Operation: Identifiable {
        let id = UUID()
        let title: String
        let commandLine: String
        let subjectIDs: [String]
        let enqueuedAt = Date()
        var startedAt: Date?
        var finishedAt: Date?
        var lines: [OutputLine] = []
        var state: OperationState = .queued

        init(title: String, commandLine: String, subjectIDs: [String] = []) {
            self.title = title
            self.commandLine = commandLine
            self.subjectIDs = subjectIDs
        }

        /// Time actually spent executing (queued time excluded).
        var duration: Double {
            guard let startedAt else { return 0 }
            return (finishedAt ?? Date()).timeIntervalSince(startedAt)
        }
    }

    var operations: [Operation] = []
    var selectedOperationID: UUID?
    var isPresented = false

    var onFinished: ((Operation) -> Void)?

    private let queue = SerialQueue()
    private var handles: [UUID: ShellHandle] = [:]
    private var cancelledIDs: Set<UUID> = []

    var runningOperation: Operation? {
        operations.last { $0.state == .running }
    }

    var queuedCount: Int {
        operations.count { $0.state == .queued }
    }

    var isBusy: Bool { operations.contains { !$0.state.isFinished } }

    /// True while an operation touching this package/service is queued or running.
    /// Lets rows disable just their own button instead of freezing the whole app.
    func isPending(subject: String) -> Bool {
        operations.contains { !$0.state.isFinished && $0.subjectIDs.contains(subject) }
    }

    var selectedOperation: Operation? {
        guard let id = selectedOperationID else { return operations.last }
        return operations.first { $0.id == id } ?? operations.last
    }

    // MARK: Running commands

    /// Runs `brew <arguments>` with live output. Returns true on success.
    @discardableResult
    func runBrew(
        title: String,
        arguments: [String],
        presentConsole: Bool = true,
        extraEnvironment: [String: String] = [:],
        subjects: [String] = [],
        preflight: (@Sendable () async -> Void)? = nil
    ) async -> Bool {
        var env = extraEnvironment
        if arguments.first != "update" && env["HOMEBREW_NO_AUTO_UPDATE"] == nil {
            env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        }
        return await run(
            title: title,
            executablePath: BrewEnvironment.current.brewPath,
            arguments: arguments,
            displayCommand: "brew " + arguments.joined(separator: " "),
            presentConsole: presentConsole,
            extraEnvironment: env,
            subjects: subjects,
            preflight: preflight
        )
    }

    @discardableResult
    func run(
        title: String,
        executablePath: String,
        arguments: [String],
        displayCommand: String? = nil,
        presentConsole: Bool = true,
        extraEnvironment: [String: String] = [:],
        subjects: [String] = [],
        preflight: (@Sendable () async -> Void)? = nil
    ) async -> Bool {
        let command = displayCommand
            ?? (URL(fileURLWithPath: executablePath).lastPathComponent + " " + arguments.joined(separator: " "))

        // The exact same command is already queued or running: don't stack a
        // duplicate, just bring the existing one into view.
        if let existing = operations.first(where: { !$0.state.isFinished && $0.commandLine == command }) {
            selectedOperationID = existing.id
            if presentConsole && UserDefaults.standard.bool(forKey: Prefs.autoOpenConsole) {
                isPresented = true
            }
            return false
        }

        let operation = Operation(title: title, commandLine: command, subjectIDs: subjects)
        operations.append(operation)
        selectedOperationID = operation.id
        if operations.count > 60 {
            operations.removeFirst(operations.count - 60)
        }
        if presentConsole && UserDefaults.standard.bool(forKey: Prefs.autoOpenConsole) {
            isPresented = true
        }

        let exitCode: Int32 = await queue.enqueue { [weak self] in
            await MainActor.run {
                operation.state = .running
                operation.startedAt = Date()
            }
            // Work that must happen right before execution (e.g. quitting an app
            // about to be upgraded) - not when the operation was merely enqueued.
            await preflight?()
            let handle = Shell.launch(executablePath, arguments, extraEnvironment: extraEnvironment)
            await MainActor.run { self?.handles[operation.id] = handle }
            var code: Int32 = -1
            var pending: [PendingLine] = []
            var lastFlush = Date()
            for await event in handle.events {
                switch event {
                case .output(let line, let isError, let overwrites):
                    if overwrites, let last = pending.indices.last {
                        pending[last] = PendingLine(text: line, isError: isError, overwritesPrevious: pending[last].overwritesPrevious)
                    } else {
                        pending.append(PendingLine(text: line, isError: isError, overwritesPrevious: overwrites))
                    }
                    if pending.count >= 20 || Date().timeIntervalSince(lastFlush) > 0.15 {
                        let batch = pending
                        pending = []
                        lastFlush = Date()
                        await MainActor.run { self?.append(batch, to: operation) }
                    }
                case .finished(let value):
                    code = value
                }
            }
            if !pending.isEmpty {
                let batch = pending
                await MainActor.run { self?.append(batch, to: operation) }
            }
            return code
        }

        handles[operation.id] = nil
        operation.finishedAt = Date()
        if cancelledIDs.contains(operation.id) || exitCode == 15 {
            operation.state = .cancelled
            cancelledIDs.remove(operation.id)
        } else {
            operation.state = exitCode == 0 ? .succeeded : .failed(exitCode)
        }
        onFinished?(operation)
        return exitCode == 0
    }

    struct PendingLine: Sendable {
        let text: String
        let isError: Bool
        let overwritesPrevious: Bool
    }

    private func append(_ batch: [PendingLine], to operation: Operation) {
        for line in batch {
            if line.overwritesPrevious, !operation.lines.isEmpty {
                operation.lines[operation.lines.count - 1] = OutputLine(text: line.text, isError: line.isError)
            } else {
                operation.lines.append(OutputLine(text: line.text, isError: line.isError))
            }
        }
        if operation.lines.count > 6000 {
            operation.lines.removeFirst(operation.lines.count - 5000)
        }
    }

    // MARK: Control

    func terminateCurrent() {
        guard let operation = runningOperation, let handle = handles[operation.id] else { return }
        cancelledIDs.insert(operation.id)
        handle.terminate()
    }

    func clearFinished() {
        operations.removeAll { $0.state.isFinished }
        if let selected = selectedOperationID, !operations.contains(where: { $0.id == selected }) {
            selectedOperationID = operations.last?.id
        }
    }
}
