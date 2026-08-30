import SwiftUI

/// Live command output docked at the bottom of the window:
/// operation list on the left, streaming output on the right.
struct ConsolePanel: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let console = app.console
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label("Console", systemImage: "terminal")
                    .font(.callout.weight(.semibold))
                if console.isBusy {
                    ProgressView().controlSize(.mini)
                }
                Spacer()
                Button("Clear Finished") {
                    console.clearFinished()
                }
                .controlSize(.small)
                .disabled(console.operations.allSatisfy { $0.state == .running })
                Button {
                    console.isPresented = false
                } label: {
                    Image(systemName: "chevron.down")
                }
                .controlSize(.small)
                .help("Hide console (⌘L)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()

            if console.operations.isEmpty {
                ContentUnavailableView(
                    "No operations yet",
                    systemImage: "terminal",
                    description: Text("Command output appears here in real time when you install, upgrade or manage packages.")
                )
                .frame(maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    operationList
                        .frame(width: 240)
                    Divider()
                    outputPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(.background)
    }

    private var operationList: some View {
        @Bindable var console = app.console
        return List(selection: $console.selectedOperationID) {
            ForEach(console.operations.reversed()) { operation in
                HStack(spacing: 8) {
                    stateIcon(for: operation.state)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(operation.title)
                            .font(.callout)
                            .lineLimit(1)
                        Text(operation.startedAt.formatted(date: .omitted, time: .standard))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .tag(operation.id)
            }
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private func stateIcon(for state: TaskConsole.OperationState) -> some View {
        switch state {
        case .running:
            ProgressView().controlSize(.small)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var outputPane: some View {
        if let operation = app.console.selectedOperation {
            VStack(spacing: 0) {
                HStack {
                    Text("$ \(operation.commandLine)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer()
                    Button {
                        let text = operation.lines.map(\.text).joined(separator: "\n")
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .help("Copy output")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(operation.lines) { line in
                                Text(line.text.isEmpty ? " " : line.text)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(lineColor(line))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(line.id)
                            }
                        }
                        .padding(10)
                    }
                    .background(Color.black.opacity(0.25))
                    .onChange(of: operation.lines.count) { _, _ in
                        if let last = operation.lines.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                    .onAppear {
                        if let last = operation.lines.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }

                Divider()
                HStack(spacing: 10) {
                    statusLabel(for: operation)
                    Text(Format.duration(operation.duration))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    if operation.state == .running {
                        Button(role: .destructive) {
                            app.console.terminateCurrent()
                        } label: {
                            Label("Stop", systemImage: "stop.fill")
                        }
                        .controlSize(.small)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        } else {
            ContentUnavailableView("Select an operation", systemImage: "terminal")
        }
    }

    private func lineColor(_ line: TaskConsole.OutputLine) -> Color {
        if line.isError { return .red.opacity(0.9) }
        if line.text.hasPrefix("==>") { return .cyan }
        if line.text.hasPrefix("Warning:") { return .yellow }
        return .primary.opacity(0.85)
    }

    @ViewBuilder
    private func statusLabel(for operation: TaskConsole.Operation) -> some View {
        switch operation.state {
        case .running:
            Label("Running…", systemImage: "circle.dotted")
                .font(.caption.weight(.medium))
                .foregroundStyle(.blue)
        case .succeeded:
            Label("Succeeded", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.green)
        case .failed(let code):
            Label("Failed (exit \(code))", systemImage: "xmark.circle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.red)
        case .cancelled:
            Label("Cancelled", systemImage: "minus.circle")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }
}
