import Darwin
import Foundation
import SwiftUI

enum RunnerState: Sendable {
    case offline, idle, busy

    var title: String {
        switch self {
        case .offline: "Offline"
        case .idle: "Idle"
        case .busy: "Running a job"
        }
    }

    var symbol: String {
        switch self {
        case .offline: "exclamationmark.triangle"
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

struct RunnerStatus: Identifiable, Sendable {
    let runner: Runner
    let state: RunnerState
    let currentJob: JobRun?
    let recentJobs: [JobRun]
    let error: String?

    var id: String { runner.id }
}

extension Array where Element == RunnerStatus {
    /// What the menu bar icon shows: a runner being down outranks one being busy.
    var overallState: RunnerState? {
        if isEmpty { return nil }
        if contains(where: { $0.state == .offline }) { return .offline }
        if contains(where: { $0.state == .busy }) { return .busy }
        return .idle
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

    private let probe = RunnerProbe()
    private var refreshLoop: Task<Void, Never>?

    init() {
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(Defaults.refreshInterval))
            }
        }
    }

    func refresh() async {
        // A failed probe keeps the last known state rather than flashing everything offline.
        if let snapshot = await probe.snapshot(historyLimit: Defaults.historyLimit) {
            statuses = snapshot
        }
        hasLoaded = true
    }
}

/// Reads every runner's state. It's an actor so the work (spawning launchctl,
/// reading logs) happens off the main thread and can't stall the menu bar.
actor RunnerProbe {
    private var links = JobLinkResolver()
    private var parsedLogs: [URL: (modified: Date, size: Int, jobs: [JobRun])] = [:]

    /// `nil` when launchd couldn't be asked which services are running.
    func snapshot(historyLimit: Int) -> [RunnerStatus]? {
        guard let servicePIDs = Launchd.runningServices() else { return nil }
        let processes = ProcessTable.snapshot()

        return RunnerDiscovery.discover().map { runner in
            let pid = servicePIDs[runner.label]
            let jobs: [JobRun]
            let logError: String?
            do {
                let parsed = try parsedJobs(at: runner.logURL)
                jobs = runner.diagURL.map { links.resolve(parsed, diagURL: $0) } ?? parsed
                logError = nil
            } catch {
                jobs = []
                logError = "Can't read \(runner.logURL.path)"
            }

            let openJob = pid == nil ? nil : jobs.last(where: { !$0.isFinished })
            let workerRunning = pid.map { ProcessTable.hasDescendant(of: $0, named: "Runner.Worker", in: processes) } ?? false
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

    /// Re-parses a log only when it changed since the last look.
    private func parsedJobs(at url: URL) throws -> [JobRun] {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let modified = attributes[.modificationDate] as? Date ?? .distantPast
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        if let cached = parsedLogs[url], cached.modified == modified, cached.size == size {
            return cached.jobs
        }
        let jobs = LogParser.parse(try LogParser.readTail(of: url))
        parsedLogs[url] = (modified, size, jobs)
        return jobs
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

    @discardableResult
    static func run(_ arguments: [String]) -> Bool {
        Shell.run("/bin/launchctl", arguments)?.status == 0
    }
}

/// The process table via libproc, so finding a runner's job worker doesn't
/// need another subprocess.
enum ProcessTable {
    struct Entry {
        let pid: pid_t
        let parent: pid_t
        let name: String
    }

    static func snapshot() -> [Entry] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        // Room for processes started between the two calls.
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = pids.withUnsafeMutableBufferPointer {
            proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size))
        }
        guard filled > 0 else { return [] }

        return pids.prefix(Int(filled)).compactMap { pid in
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
            let name = withUnsafeBytes(of: info.pbi_comm) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
            return Entry(pid: pid, parent: pid_t(info.pbi_ppid), name: name)
        }
    }

    static func hasDescendant(of root: pid_t, named name: String, in table: [Entry]) -> Bool {
        let children = Dictionary(grouping: table, by: \.parent)
        var queue = [root]
        while let pid = queue.popLast() {
            for child in children[pid] ?? [] {
                if child.name == name { return true }
                queue.append(child.pid)
            }
        }
        return false
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
