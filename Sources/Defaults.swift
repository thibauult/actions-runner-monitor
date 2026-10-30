import Foundation

/// User settings, kept in the app's defaults domain. They can be changed in the
/// Settings window or with `defaults write <bundle id> <key> <value>`.
enum Defaults {
    static let refreshIntervalKey = "refreshInterval"
    static let backgroundRefreshIntervalKey = "backgroundRefreshInterval"
    static let historyLimitKey = "historyLimit"
    static let hiddenRunnersKey = "hiddenRunners"
    static let notifyOnJobStartKey = "notifyOnJobStart"

    static let defaultRefreshInterval = 3.0
    static let defaultBackgroundRefreshInterval = 20.0
    static let defaultHistoryLimit = 10
    static let defaultNotifyOnJobStart = true

    static func register() {
        UserDefaults.standard.register(defaults: [
            refreshIntervalKey: defaultRefreshInterval,
            backgroundRefreshIntervalKey: defaultBackgroundRefreshInterval,
            historyLimitKey: defaultHistoryLimit,
            notifyOnJobStartKey: defaultNotifyOnJobStart,
        ])
    }

    static var notifyOnJobStart: Bool { UserDefaults.standard.bool(forKey: notifyOnJobStartKey) }

    static var refreshInterval: Double { max(1, UserDefaults.standard.double(forKey: refreshIntervalKey)) }
    /// How often to poll while the panel is closed; job changes arrive through the log watcher.
    static var backgroundRefreshInterval: Double { max(5, UserDefaults.standard.double(forKey: backgroundRefreshIntervalKey)) }
    static var historyLimit: Int { max(1, UserDefaults.standard.integer(forKey: historyLimitKey)) }
}

/// launchd labels of runners hidden from the menu, stored as one comma-separated
/// string so `@AppStorage` can hold it.
struct LabelSet: RawRepresentable, Equatable {
    var labels: Set<String>

    init(_ labels: Set<String> = []) { self.labels = labels }
    init?(rawValue: String) { labels = Set(rawValue.split(separator: ",").map(String.init)) }
    var rawValue: String { labels.sorted().joined(separator: ",") }
}
