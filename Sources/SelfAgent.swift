import AppKit

/// Runs the monitor itself as a launchd agent with KeepAlive, so it starts at
/// login and comes back after a crash or after something other than its own
/// Quit button closes it.
enum SelfAgent {
    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    static var label: String { Bundle.main.bundleIdentifier ?? "actions-runner-monitor" }

    static var plistURL: URL {
        RunnerDiscovery.launchAgentsURL.appendingPathComponent("\(label).plist")
    }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    /// launchd sets XPC_SERVICE_NAME to the label of the job it started.
    static var isRunningUnderLaunchd: Bool {
        ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == label
    }

    private static var serviceTarget: String { "\(Launchd.guiDomain)/\(label)" }

    /// Writes and loads the agent. launchd starts its own copy right away, and that
    /// copy closes this one (see `Startup`).
    static func install() throws {
        guard let executable = Bundle.main.executablePath else {
            throw Failure(errorDescription: "Can't find the app's executable.")
        }
        let job: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: plistURL, options: .atomic)

        Launchd.run(["bootout", serviceTarget])
        guard Launchd.run(["bootstrap", Launchd.guiDomain, plistURL.path]) else {
            try? FileManager.default.removeItem(at: plistURL)
            throw Failure(errorDescription: "launchctl couldn't load \(plistURL.path).")
        }
    }

    /// Removes the agent and stops launchd's copy. When that copy is this process,
    /// a plain copy is opened first to take over.
    static func uninstall() throws {
        try FileManager.default.removeItem(at: plistURL)
        if isRunningUnderLaunchd {
            openReplacement()
        }
        Launchd.run(["bootout", serviceTarget])
    }

    /// Starts launchd's copy, loading the agent first if it isn't loaded this session.
    static func start() {
        if !Launchd.run(["kickstart", serviceTarget]) {
            Launchd.run(["bootstrap", Launchd.guiDomain, plistURL.path])
        }
    }

    /// Quit from the menu. Under launchd, unloading the job is what stops it
    /// from coming straight back; it loads again at next login.
    static func quit() {
        if isRunningUnderLaunchd {
            Launchd.run(["bootout", serviceTarget])
        }
        NSApp.terminate(nil)
    }

    private static func openReplacement() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = [Startup.waitForPIDFlag, String(getpid())]
        let opened = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            opened.signal()
        }
        _ = opened.wait(timeout: .now() + 5)
    }
}

/// Keeps exactly one monitor on the menu bar, preferring launchd's copy.
enum Startup {
    static let waitForPIDFlag = "--wait-for-pid"

    /// `false` when this instance should exit straight away.
    static func shouldRun(arguments: [String]) -> Bool {
        if let flag = arguments.firstIndex(of: waitForPIDFlag),
           arguments.indices.contains(flag + 1),
           let pid = pid_t(arguments[flag + 1]) {
            waitForExit(of: pid)
        }

        let others = NSRunningApplication.runningApplications(withBundleIdentifier: SelfAgent.label)
            .filter { $0.processIdentifier != getpid() }

        if SelfAgent.isRunningUnderLaunchd {
            others.forEach { $0.terminate() }
            return true
        }
        if SelfAgent.isInstalled {
            // Opened from Finder or Spotlight: hand over to launchd's copy.
            SelfAgent.start()
            return false
        }
        if let other = others.first {
            other.activate()
            return false
        }
        return true
    }

    private static func waitForExit(of pid: pid_t) {
        for _ in 0..<50 where kill(pid, 0) == 0 {
            usleep(100_000)
        }
    }
}
