import SwiftUI

struct ActionsRunnerMonitorApp: App {
    @StateObject private var monitor = Monitor()

    var body: some Scene {
        MenuBarExtra {
            MonitorPanel(monitor: monitor)
        } label: {
            MenuBarLabel(monitor: monitor)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(monitor: monitor)
        }
    }
}

@main
enum Entry {
    static func main() {
        Defaults.register()
        let arguments = CommandLine.arguments

        // `ActionsRunnerMonitor --dump [log]` prints what the monitor sees and exits,
        // to check discovery and the parser without opening the UI.
        if let flag = arguments.firstIndex(of: "--dump") {
            if arguments.indices.contains(flag + 1) {
                dump(log: (try? String(contentsOfFile: arguments[flag + 1], encoding: .utf8)) ?? "")
            } else {
                dumpRunners()
            }
            return
        }

        // Same as the "Start at login and reopen if it quits" setting, for scripts.
        if arguments.contains("--install-agent") || arguments.contains("--uninstall-agent") {
            do {
                if arguments.contains("--install-agent") {
                    try SelfAgent.install()
                    print("Installed \(SelfAgent.plistURL.path)")
                } else {
                    try SelfAgent.uninstall()
                    print("Removed \(SelfAgent.plistURL.path)")
                }
            } catch {
                FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                exit(1)
            }
            return
        }

        guard Startup.shouldRun(arguments: arguments) else { return }
        ActionsRunnerMonitorApp.main()
    }

    private static func dumpRunners() {
        let services = Launchd.runningServices() ?? [:]
        let runners = RunnerDiscovery.discover()
        if runners.isEmpty {
            print("No actions.runner.* agents in \(RunnerDiscovery.launchAgentsURL.path)")
        }
        for runner in runners {
            let pid = services[runner.label].map { "pid \($0)" } ?? "not running"
            print("\(runner.name) [\(runner.label)] \(pid)")
            print("  log: \(runner.logURL.path)")
            print("  github: \(runner.settingsURL?.absoluteString ?? "-")")
            dump(log: (try? LogParser.readTail(of: runner.logURL)) ?? "", indent: "  ")
        }
    }

    private static func dump(log: String, indent: String = "") {
        for job in LogParser.parse(log).suffix(Defaults.historyLimit) {
            let duration = job.finishedAt.map { Format.duration(from: job.startedAt, to: $0) }
                ?? (job.isFinished ? "-" : "running")
            print("\(indent)\(job.name) | \(job.result ?? "-") | \(duration)")
        }
    }
}
