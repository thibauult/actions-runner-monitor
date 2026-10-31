import Darwin
import Foundation
import SwiftUI

enum RunnerState: Sendable, Equatable {
    case offline, idle, busy

    var title: String {
        switch self {
        case .offline: "Paused"
        case .idle: "Idle"
        case .busy: "Running a job"
        }
    }

    var symbol: String {
        switch self {
        case .offline: "pause.circle"
        case .idle: "checkmark.circle"
        case .busy: "gearshape.2.fill"
        }
    }

    var color: Color {
        switch self {
        case .offline: .orange
        case .idle: .green
        case .busy: .blue
        }
    }
}

struct RunnerStatus: Identifiable, Sendable, Equatable {
    let runner: Runner
    let state: RunnerState
    let currentJob: JobRun?
    let recentJobs: [JobRun]
    let error: String?

    var id: String { runner.id }
}

extension Array where Element == RunnerStatus {
    /// What the menu bar icon shows: a service being down outranks one being busy.
    /// A terminal runner that isn't running is normal, so it only shows if nothing else does.
    var overallState: RunnerState? {
        if isEmpty { return nil }
        if contains(where: { $0.state == .offline && $0.runner.isService }) { return .offline }
        if contains(where: { $0.state == .busy }) { return .busy }
        return contains(where: { $0.state == .idle }) ? .idle : .offline
    }

    /// The longest-running job, for the menu bar timer.
    var oldestCurrentJob: JobRun? {
        compactMap(\.currentJob).min { $0.startedAt < $1.startedAt }
    }
}

@MainActor
final class Monitor: ObservableObject {
    @Published private(set) var statuses: [RunnerStatus] = []
    @Published private(set) var hasLoaded = false
    /// Runners with a start or stop in flight, and the state each is heading to (true = running).
    @Published private(set) var pending: [String: Bool] = [:]
    @Published private(set) var actionErrors: [String: String] = [:]
    /// Whether the panel is on screen. It decides how often to poll.
    @Published private(set) var panelVisible = false

    private let probe = RunnerProbe()
    private let logWatcher = LogWatcher()
    private var refreshLoop: Task<Void, Never>?
    private var announcedJobs: Set<String> = []

    private var sleeper: CheckedContinuation<Void, Never>?
    private var sleepTimer: Timer?
    private var wakePending = false
    private var rediscoverPending = true

    init() {
        logWatcher.onChange = { [weak self] in
            Task { @MainActor in self?.wake() }
        }
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                await self?.sleep()
            }
        }
    }

    func refresh() async {
        let rediscover = rediscoverPending
        rediscoverPending = false
        // A failed probe keeps the last known state rather than flashing everything offline.
        if let snapshot = await probe.snapshot(historyLimit: Defaults.historyLimit, rediscover: rediscover) {
            notifyOfNewJobs(in: snapshot)
            logWatcher.watch(snapshot.map(\.runner.logURL))
            // Republishing identical state re-lays out the status item and can swallow clicks.
            if snapshot != statuses { statuses = snapshot }
        }
        hasLoaded = true
    }

    /// The panel polls fast so its timers and states are live. Closed, the log
    /// watcher reports job changes, so polling only has to notice a service
    /// going down, and can be rare.
    func setPanelVisible(_ visible: Bool) {
        guard visible != panelVisible else { return }
        panelVisible = visible
        if visible {
            rediscoverPending = true
            wake()
        }
    }

    /// Picks up a change to the list of runner directories now.
    func rediscover() {
        rediscoverPending = true
        wake()
    }

    /// Starts or stops a runner's launchd service.
    func setRunning(_ running: Bool, for runner: Runner) async {
        guard pending[runner.id] == nil else { return }
        pending[runner.id] = running
        actionErrors[runner.id] = nil
        let failure = await Task.detached { running ? Launchd.start(runner) : Launchd.stop(runner) }.value
        actionErrors[runner.id] = failure
        pending[runner.id] = nil
        await refresh()
    }

    /// Sleeps until the next poll, or until `wake()`.
    private func sleep() async {
        if wakePending {
            wakePending = false
            return
        }
        let seconds = panelVisible ? Defaults.refreshInterval : Defaults.backgroundRefreshInterval
        await withCheckedContinuation { continuation in
            sleeper = continuation
            // Generous tolerance lets the system batch this wake-up with others.
            let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.wake() }
            }
            timer.tolerance = seconds * 0.5
            RunLoop.main.add(timer, forMode: .common)
            sleepTimer = timer
        }
    }

    private func wake() {
        sleepTimer?.invalidate()
        sleepTimer = nil
        if let sleeper {
            self.sleeper = nil
            sleeper.resume()
        } else {
            wakePending = true
        }
    }

    /// Jobs already running when the app starts are seeded silently, so only
    /// jobs that start while it's watching notify.
    private func notifyOfNewJobs(in snapshot: [RunnerStatus]) {
        for status in snapshot {
            guard let job = status.currentJob else { continue }
            let key = "\(status.id)|\(job.startedAt.timeIntervalSince1970)"
            guard announcedJobs.insert(key).inserted, hasLoaded, Defaults.notifyOnJobStart else { continue }
            Notifier.jobStarted(job, on: status.runner)
        }
    }
}

/// Wakes the monitor when a runner's log is written, so job starts and ends show
/// up at once without polling for them.
final class LogWatcher: @unchecked Sendable {
    var onChange: (@Sendable () -> Void)?

    private let queue = DispatchQueue(label: "log-watcher", qos: .utility)
    private var sources: [URL: DispatchSourceFileSystemObject] = [:]

    /// Watches exactly `urls`. Safe to call on every refresh: files already watched
    /// are left alone, and ones replaced or not yet created are picked up again.
    func watch(_ urls: [URL]) {
        queue.async { [self] in
            for (url, source) in sources where !urls.contains(url) {
                source.cancel()
                sources[url] = nil
            }
            for url in urls where sources[url] == nil {
                let descriptor = open(url.path, O_EVTONLY)
                guard descriptor >= 0 else { continue }
                let source = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: descriptor,
                    eventMask: [.write, .extend, .delete, .rename],
                    queue: queue
                )
                source.setEventHandler { [weak self, weak source] in
                    guard let self, let source else { return }
                    if !source.data.isDisjoint(with: [.delete, .rename]) {
                        // Rotated or removed: drop it; the next refresh reopens the new file.
                        source.cancel()
                        if sources[url] === source { sources[url] = nil }
                    }
                    onChange?()
                }
                source.setCancelHandler { close(descriptor) }
                source.resume()
                sources[url] = source
            }
        }
    }
}

/// Reads every runner's state. It's an actor so the work (spawning launchctl,
/// reading logs) happens off the main thread and can't stall the menu bar.
actor RunnerProbe {
    private var links = JobLinkResolver()
    private var parsedLogs: [URL: (modified: Date, size: Int, jobs: [JobRun])] = [:]
    private var resolved: [URL: (stamp: Stamp, jobs: [JobRun])] = [:]
    private var discovered: (stamp: DiscoveryStamp, runners: [Runner])?

    private struct DiscoveryStamp: Equatable {
        let launchAgents: Date?
        let directories: [String]
        let diags: [Date?]
    }

    private struct Stamp: Equatable {
        let log: Date
        let logSize: Int
        let diag: Date?
    }

    /// `nil` when launchd couldn't be asked which services are running.
    func snapshot(historyLimit: Int, rediscover: Bool) -> [RunnerStatus]? {
        guard let servicePIDs = Launchd.runningServices() else { return nil }

        return runners(forceRefresh: rediscover).map { runner in
            let pid = ProcessTable.pid(of: runner, services: servicePIDs)
            let jobs: [JobRun]
            let logError: String?
            do {
                jobs = try resolvedJobs(for: runner)
                logError = nil
            } catch {
                jobs = []
                // A terminal runner that never started has no log yet.
                logError = runner.isService ? "Can't read \(runner.logURL.path)" : nil
            }

            let openJob = pid == nil ? nil : jobs.last(where: { !$0.isFinished })
            // The log usually says it already; only otherwise look at the process tree.
            let workerRunning = openJob == nil && (pid.map { ProcessTable.hasDescendant(of: $0, named: "Runner.Worker") } ?? false)
            let state: RunnerState = pid == nil ? .offline : (openJob != nil || workerRunning ? .busy : .idle)

            return RunnerStatus(
                runner: runner,
                state: state,
                currentJob: openJob,
                recentJobs: Array(jobs.filter(\.isFinished).suffix(historyLimit).reversed()),
                error: logError
            )
        }
    }

    /// The plists are re-read only when the LaunchAgents folder changed, and runner
    /// directories only when one's `_diag` did: a listener start adds a new log there.
    private func runners(forceRefresh: Bool) -> [Runner] {
        let directories = Defaults.runnerDirectories
        let stamp = DiscoveryStamp(
            launchAgents: Self.modificationDate(of: RunnerDiscovery.launchAgentsURL),
            directories: directories,
            diags: directories.map { Self.modificationDate(of: URL(fileURLWithPath: $0).appendingPathComponent("_diag")) }
        )
        if !forceRefresh, let discovered, discovered.stamp == stamp { return discovered.runners }
        let runners = RunnerDiscovery.discover()
        discovered = (stamp, runners)
        return runners
    }

    /// Jobs with their GitHub links. Redone only when the log or the `_diag` folder
    /// changed, or while a recent job still waits for its worker log to show up.
    private func resolvedJobs(for runner: Runner) throws -> [JobRun] {
        let attributes = try FileManager.default.attributesOfItem(atPath: runner.logURL.path)
        let stamp = Stamp(
            log: attributes[.modificationDate] as? Date ?? .distantPast,
            logSize: (attributes[.size] as? NSNumber)?.intValue ?? 0,
            diag: runner.diagURL.flatMap(Self.modificationDate(of:))
        )
        if let cached = resolved[runner.logURL], cached.stamp == stamp,
           !cached.jobs.contains(where: { $0.url == nil && $0.startedAt.timeIntervalSinceNow > -300 }) {
            return cached.jobs
        }

        let parsed = try parsedJobs(at: runner.logURL, stamp: stamp)
        let jobs = runner.diagURL.map { links.resolve(parsed, diagURL: $0) } ?? parsed
        resolved[runner.logURL] = (stamp, jobs)
        return jobs
    }

    /// Re-parses a log only when it changed since the last look.
    private func parsedJobs(at url: URL, stamp: Stamp) throws -> [JobRun] {
        if let cached = parsedLogs[url], cached.modified == stamp.log, cached.size == stamp.logSize {
            return cached.jobs
        }
        let jobs = LogParser.parse(try LogParser.readTail(of: url))
        parsedLogs[url] = (stamp.log, stamp.logSize, jobs)
        return jobs
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}

enum Launchd {
    static var guiDomain: String { "gui/\(getuid())" }

    /// PIDs of the running jobs in this user's launchd domain, by label.
    static func runningServices() -> [String: pid_t]? {
        guard let result = Shell.run("/bin/launchctl", ["list"]), result.status == 0 else { return nil }
        var pids: [String: pid_t] = [:]
        // "PID\tStatus\tLabel", with "-" as the PID of a job that isn't running.
        for line in result.output.split(separator: "\n").dropFirst() {
            let fields = line.split(separator: "\t")
            if fields.count == 3, let pid = pid_t(fields[0]) {
                pids[String(fields[2])] = pid
            }
        }
        return pids
    }

    /// Loads a runner's service (which starts it), or kicks it if it's loaded but not running.
    /// Returns an error message, or `nil` on success.
    static func start(_ runner: Runner) -> String? {
        guard let plistURL = runner.plistURL else { return "\(runner.name) has no service to start" }
        let bootstrap = Shell.run("/bin/launchctl", ["bootstrap", guiDomain, plistURL.path])
        if bootstrap?.status == 0 { return nil }
        if Shell.run("/bin/launchctl", ["kickstart", "\(guiDomain)/\(runner.label)"])?.status == 0 { return nil }
        return failure("Couldn't start \(runner.name)", bootstrap?.output)
    }

    /// Unloads a runner's service, which ends it and any job it is running.
    static func stop(_ runner: Runner) -> String? {
        let result = Shell.run("/bin/launchctl", ["bootout", "\(guiDomain)/\(runner.label)"])
        return result?.status == 0 ? nil : failure("Couldn't stop \(runner.name)", result?.output)
    }

    private static func failure(_ summary: String, _ output: String?) -> String {
        let detail = output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return detail.isEmpty ? summary : "\(summary): \(detail)"
    }

    @discardableResult
    static func run(_ arguments: [String]) -> Bool {
        Shell.run("/bin/launchctl", arguments)?.status == 0
    }
}

/// Walks a service's children via libproc, without a subprocess or a scan of
/// every process on the machine.
enum ProcessTable {
    /// The running listener of a service (from launchd's `services`) or terminal runner.
    static func pid(of runner: Runner, services: [String: pid_t]) -> pid_t? {
        if runner.isService { return services[runner.label] }
        return runner.workDirectory.flatMap(listenerPID(in:))
    }

    /// The listener running from `directory`'s `bin` (or `bin.<version>`, after an
    /// update) folder. Terminal runners have no service to ask, so this scans all processes.
    private static func listenerPID(in directory: URL) -> pid_t? {
        guard let resolved = realpath(directory.path, nil) else { return nil }
        defer { free(resolved) }
        let root = String(cString: resolved)
        return allProcesses().first { pid in
            let executable = URL(fileURLWithPath: executablePath(pid))
            return executable.lastPathComponent == "Runner.Listener"
                && executable.deletingLastPathComponent().deletingLastPathComponent().path == root
        }
    }

    private static func allProcesses() -> [pid_t] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        var buffer = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&buffer, Int32(capacity * MemoryLayout<pid_t>.size)))
        return Array(buffer.prefix(max(0, count)))
    }

    private static func executablePath(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return String(cString: buffer)
    }

    static func hasDescendant(of root: pid_t, named name: String) -> Bool {
        var queue = [root]
        while let pid = queue.popLast() {
            for child in children(of: pid) {
                if processName(child) == name { return true }
                queue.append(child)
            }
        }
        return false
    }

    private static func children(of pid: pid_t) -> [pid_t] {
        var capacity = 32
        while true {
            var buffer = [pid_t](repeating: 0, count: capacity)
            let count = Int(proc_listchildpids(pid, &buffer, Int32(capacity * MemoryLayout<pid_t>.size)))
            if count < capacity { return Array(buffer.prefix(max(0, count))) }
            capacity *= 4
        }
    }

    private static func processName(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 64)
        proc_name(pid, &buffer, UInt32(buffer.count))
        return String(cString: buffer)
    }
}

enum Shell {
    /// Runs a command and returns its exit status and combined output, or `nil`
    /// if it couldn't start or didn't finish within `timeout`.
    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 5) -> (status: Int32, output: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return nil
        }

        // Drain the pipe while waiting, or a large output fills it and the child blocks.
        var data = Data()
        let reading = DispatchGroup()
        reading.enter()
        DispatchQueue.global(qos: .utility).async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            reading.leave()
        }
        if reading.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
