import AppKit
import SwiftUI

enum Format {
    static func duration(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        let (h, m, s) = (seconds / 3600, seconds % 3600 / 60, seconds % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func minutes(from start: Date, to end: Date) -> String {
        let m = max(0, Int(end.timeIntervalSince(start))) / 60
        return m >= 60 ? "\(m / 60)h\(String(format: "%02d", m % 60))" : "\(m)m"
    }

    static func resultSymbol(_ result: String?) -> (String, Color) {
        switch result {
        case "Succeeded": ("checkmark.circle.fill", .green)
        case "Failed": ("xmark.circle.fill", .red)
        case "Canceled", "Cancelled": ("slash.circle.fill", .secondary)
        default: ("exclamationmark.circle.fill", .orange)
        }
    }
}

struct MenuBarLabel: View {
    @ObservedObject var monitor: Monitor
    @AppStorage(Defaults.hiddenRunnersKey) private var hidden = LabelSet()

    var body: some View {
        let visible = monitor.statuses.filter { !hidden.labels.contains($0.id) }
        let symbol = visible.overallState?.symbol ?? "questionmark.circle"
        if let job = visible.oldestCurrentJob {
            // Ticks once a minute: a per-second label resizes the status item constantly
            // and makes the menu unclickable.
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Image(nsImage: GitHubMark.image)
                Image(systemName: symbol)
                Text(Format.minutes(from: job.startedAt, to: context.date))
            }
        } else {
            Image(nsImage: GitHubMark.image)
            Image(systemName: symbol)
        }
    }
}

/// Reports whether the hosting window is on screen. The menu bar window's content
/// stays alive while it's closed, so `onAppear` can't tell.
struct WindowVisibility: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = TrackingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? TrackingView)?.onChange = onChange
    }

    private final class TrackingView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            observer.map(NotificationCenter.default.removeObserver)
            observer = nil
            guard let window else {
                onChange?(false)
                return
            }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in self?.report() }
            report()
        }

        private func report() {
            onChange?(window?.occlusionState.contains(.visible) ?? false)
        }

        deinit { observer.map(NotificationCenter.default.removeObserver) }
    }
}

struct MonitorPanel: View {
    @ObservedObject var monitor: Monitor
    @AppStorage(Defaults.hiddenRunnersKey) private var hidden = LabelSet()
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let visible = monitor.statuses.filter { !hidden.labels.contains($0.id) }
        VStack(alignment: .leading, spacing: 12) {
            if visible.isEmpty {
                Text(emptyMessage).foregroundStyle(.secondary)
            }
            ForEach(visible) { status in
                RunnerSection(status: status, monitor: monitor)
                if status.id != visible.last?.id {
                    Divider()
                }
            }

            Divider()

            HStack {
                Button("Settings…") {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }
                Spacer()
                Button("Quit") { SelfAgent.quit() }
            }
        }
        .padding()
        .frame(width: 360)
        .background(WindowVisibility { monitor.setPanelVisible($0) })
    }

    private var emptyMessage: String {
        if !monitor.hasLoaded { return "Looking for runners…" }
        if !monitor.statuses.isEmpty { return "All runners are hidden. Show them in Settings." }
        return "No runners found. Install a runner as a service with ./svc.sh install and it shows up here."
    }
}

struct RunnerSection: View {
    let status: RunnerStatus
    @ObservedObject var monitor: Monitor

    private var isPending: Bool { monitor.pending[status.id] != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(status.runner.name).font(.headline)
                    if let scope = status.runner.scope {
                        Text(scope).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Label(status.state.title, systemImage: status.state.symbol)
                    .foregroundStyle(status.state.color)
                    .font(.subheadline)
                Toggle("Running", isOn: runningBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(isPending)
                    .help(status.state == .offline ? "Start this runner" : "Stop this runner")
            }

            if let job = status.currentJob {
                currentJobView(job)
            } else if status.state == .busy {
                Text("A job is starting…").foregroundStyle(.secondary)
            }

            if status.recentJobs.isEmpty {
                Text("No finished jobs in the log yet.").foregroundStyle(.secondary)
            } else {
                ForEach(status.recentJobs) { job in
                    recentJobRow(job)
                }
            }

            if let error = status.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            if let error = monitor.actionErrors[status.id] {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Button("Open log") { NSWorkspace.shared.open(status.runner.logURL) }
                if let url = status.runner.settingsURL {
                    Button("Open on GitHub") { NSWorkspace.shared.open(url) }
                }
            }
            .controlSize(.small)
        }
    }

    /// On while the service is up. Flipping it asks launchd; the state follows on the next refresh.
    private var runningBinding: Binding<Bool> {
        Binding(
            get: { isPending ? pendingTarget : status.state != .offline },
            set: { toggle(running: $0) }
        )
    }

    private var pendingTarget: Bool { monitor.pending[status.id] ?? false }

    private func toggle(running: Bool) {
        if !running, status.state == .busy, !confirmStop() { return }
        Task { await monitor.setRunning(running, for: status.runner) }
    }

    private func confirmStop() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Stop \(status.runner.name)?"
        alert.informativeText = "It is running a job, which will be cancelled."
        alert.addButton(withTitle: "Stop Runner")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    @ViewBuilder
    private func linked<Content: View>(_ job: JobRun, @ViewBuilder content: () -> Content) -> some View {
        if let url = job.url {
            Button { NSWorkspace.shared.open(url) } label: {
                content().contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open this job on GitHub")
        } else {
            content()
        }
    }

    private func currentJobView(_ job: JobRun) -> some View {
        linked(job) { currentJobContent(job) }
    }

    private func currentJobContent(_ job: JobRun) -> some View {
        // Ticking only while the panel is open: a closed window shouldn't redraw every second.
        TimelineView(.periodic(from: .now, by: monitor.panelVisible ? 1 : 3600)) { context in
            VStack(alignment: .leading, spacing: 4) {
                Text(job.title).font(.body.weight(.semibold))
                Text("Started \(job.startedAt.formatted(date: .omitted, time: .shortened)) · \(Format.duration(from: job.startedAt, to: context.date)) elapsed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func recentJobRow(_ job: JobRun) -> some View {
        linked(job) { recentJobContent(job) }
    }

    private func recentJobContent(_ job: JobRun) -> some View {
        let (symbol, color) = Format.resultSymbol(job.result)
        return HStack(alignment: .firstTextBaseline) {
            Image(systemName: symbol).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.title).lineLimit(1)
                Text("\(job.result ?? "") · \(job.startedAt.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let end = job.finishedAt {
                Text(Format.duration(from: job.startedAt, to: end))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var monitor: Monitor
    @AppStorage(Defaults.refreshIntervalKey) private var refreshInterval = Defaults.defaultRefreshInterval
    @AppStorage(Defaults.backgroundRefreshIntervalKey) private var backgroundRefreshInterval = Defaults.defaultBackgroundRefreshInterval
    @AppStorage(Defaults.historyLimitKey) private var historyLimit = Defaults.defaultHistoryLimit
    @AppStorage(Defaults.hiddenRunnersKey) private var hidden = LabelSet()
    @AppStorage(Defaults.notifyOnJobStartKey) private var notifyOnJobStart = Defaults.defaultNotifyOnJobStart
    @State private var keepsRunning = SelfAgent.isInstalled
    @State private var agentError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Start at login and reopen if it quits", isOn: $keepsRunning)
                    .onChange(of: keepsRunning) { _, enabled in setKeepsRunning(enabled) }
                if let agentError {
                    Text(agentError).font(.caption).foregroundStyle(.red)
                }
            } footer: {
                Text("Runs the monitor as a launchd agent. Quit from the menu still stops it until your next login.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Notify when a job starts", isOn: $notifyOnJobStart)
                    .onChange(of: notifyOnJobStart) { _, enabled in
                        if enabled { Notifier.requestAuthorization() }
                    }
            } header: {
                Text("Notifications")
            } footer: {
                Text("If nothing appears, allow notifications for this app in System Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Display") {
                Stepper(value: $refreshInterval, in: 1...60, step: 1) {
                    Text("Check every \(Int(refreshInterval)) s while open")
                }
                Stepper(value: $backgroundRefreshInterval, in: 5...300, step: 5) {
                    Text("Check every \(Int(backgroundRefreshInterval)) s in the background")
                }
                Stepper(value: $historyLimit, in: 1...50) {
                    Text("Show \(historyLimit) recent jobs per runner")
                }
            }

            Section {
                if monitor.statuses.isEmpty {
                    Text("No runners found.").foregroundStyle(.secondary)
                }
                ForEach(monitor.statuses.map(\.runner)) { runner in
                    Toggle(isOn: shown(runner)) {
                        Text(runner.name)
                        Text(runner.label)
                    }
                }
            } header: {
                Text("Runners")
            } footer: {
                Text("Every runner installed with ./svc.sh install (an actions.runner.* agent in ~/Library/LaunchAgents) is picked up automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func shown(_ runner: Runner) -> Binding<Bool> {
        Binding(
            get: { !hidden.labels.contains(runner.label) },
            set: { show in
                if show { hidden.labels.remove(runner.label) } else { hidden.labels.insert(runner.label) }
            }
        )
    }

    private func setKeepsRunning(_ enabled: Bool) {
        guard enabled != SelfAgent.isInstalled else { return }
        do {
            if enabled {
                try SelfAgent.install()
            } else {
                try SelfAgent.uninstall()
            }
            agentError = nil
        } catch {
            agentError = error.localizedDescription
            keepsRunning = SelfAgent.isInstalled
        }
    }
}
