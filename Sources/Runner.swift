import Foundation

/// A self-hosted runner installed as a launchd service with `./svc.sh install`.
/// Everything here is read from files the runner itself wrote, so the app holds
/// no knowledge of any particular runner.
struct Runner: Identifiable, Hashable, Sendable {
    /// launchd label, `actions.runner.<scope>.<name>`.
    let label: String
    /// The launchd plist `svc.sh install` wrote; loading it starts the service.
    let plistURL: URL
    /// Runner name as registered on GitHub.
    let name: String
    /// The service's stdout, where the listener prints one line per job start and end.
    let logURL: URL
    /// Org, repo or enterprise the runner is registered to.
    let gitHubURL: URL?
    let agentID: Int?
    /// The runner's install directory; its `_diag` folder holds the per-job worker logs.
    let workDirectory: URL?

    var id: String { label }

    var diagURL: URL? { workDirectory?.appendingPathComponent("_diag") }

    /// `my-org` or `owner/repo`, for display.
    var scope: String? {
        gitHubURL.map { $0.pathComponents.filter { $0 != "/" }.joined(separator: "/") }
    }

    /// The runner's page in the GitHub settings of whatever it's registered to.
    var settingsURL: URL? {
        guard let gitHubURL, let host = gitHubURL.host() else { return nil }
        let parts = gitHubURL.pathComponents.filter { $0 != "/" }
        let settings: String
        switch parts.count {
        case 1: settings = "organizations/\(parts[0])"
        case 2 where parts[0] == "enterprises": settings = "enterprises/\(parts[1])"
        case 2: settings = "\(parts[0])/\(parts[1])"
        default: return gitHubURL
        }
        let runnerPath = agentID.map { "/\($0)" } ?? ""
        return URL(string: "\(gitHubURL.scheme ?? "https")://\(host)/\(settings)/settings/actions/runners\(runnerPath)")
    }
}

enum RunnerDiscovery {
    static let labelPrefix = "actions.runner."

    static var launchAgentsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
    }

    static func discover() -> [Runner] {
        let files = (try? FileManager.default.contentsOfDirectory(at: launchAgentsURL, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix(labelPrefix) && $0.pathExtension == "plist" }
            .compactMap(runner(fromServicePlist:))
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func runner(fromServicePlist url: URL) -> Runner? {
        guard let data = try? Data(contentsOf: url),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let label = plist["Label"] as? String else { return nil }

        let logURL = (plist["StandardOutPath"] as? String).map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/\(label)/stdout.log")
        let workDirectory = (plist["WorkingDirectory"] as? String).map(URL.init(fileURLWithPath:))
        let settings = workDirectory.flatMap(runnerSettings(in:)) ?? [:]

        return Runner(
            label: label,
            plistURL: url,
            name: settings["agentName"] as? String ?? String(label.dropFirst(labelPrefix.count)),
            logURL: logURL,
            gitHubURL: (settings["gitHubUrl"] as? String).flatMap(URL.init(string:)),
            agentID: settings["agentId"] as? Int,
            workDirectory: workDirectory
        )
    }

    /// The `.runner` file `config.sh` writes: JSON, with a UTF-8 BOM.
    private static func runnerSettings(in directory: URL) -> [String: Any]? {
        guard var data = try? Data(contentsOf: directory.appendingPathComponent(".runner")) else { return nil }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { data = Data(data.dropFirst(3)) }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
