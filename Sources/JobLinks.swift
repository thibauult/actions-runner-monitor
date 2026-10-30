import Foundation

// The listener's stdout log names a job but not where it ran. The worker that
// executes each job writes `_diag/Worker_<utc timestamp>.log`, which starts with
// the job message: display name, repository, run id and check run id.

struct WorkerLogInfo: Sendable {
    let startedAt: Date
    let jobName: String
    let url: URL
    let repo: String
}

struct JobLinkResolver {
    private var cache: [URL: WorkerLogInfo] = [:]
    /// Old worker logs without a job message (a runner update, say); not worth reading again.
    private var unreadable: Set<URL> = []

    private static let fileName = #/^Worker_(\d{8}-\d{6})-utc\.log$/#
    private static let jobName = #/"jobDisplayName": "((?:[^"\\]|\\.)*)"/#
    private static let repository = #/"k": "repository",\s*"v": "([^"]+)"/#
    private static let runID = #/"k": "run_id",\s*"v": "(\d+)"/#
    private static let serverURL = #/"k": "server_url",\s*"v": "([^"]+)"/#
    private static let checkRunID = #/"k": "check_run_id",\s*"v": (\d+)/#

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    /// Fills in `url` for every job it can match to a worker log.
    mutating func resolve(_ jobs: [JobRun], diagURL: URL) -> [JobRun] {
        let workers = workerLogs(in: diagURL)
        return jobs.map { job in
            var job = job
            // The worker starts a moment after the listener prints "Running job".
            let match = workers
                .filter { $0.jobName == job.name && abs($0.startedAt.timeIntervalSince(job.startedAt)) < 300 }
                .min { abs($0.startedAt.timeIntervalSince(job.startedAt)) < abs($1.startedAt.timeIntervalSince(job.startedAt)) }
            job.url = match?.url
            job.repo = match?.repo
            return job
        }
    }

    private mutating func workerLogs(in directory: URL) -> [WorkerLogInfo] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var infos: [WorkerLogInfo] = []
        var seen: Set<URL> = []
        for file in files {
            guard let match = file.lastPathComponent.wholeMatch(of: Self.fileName),
                  let started = Self.dateFormatter.date(from: String(match.1)) else { continue }
            seen.insert(file)
            if let cached = cache[file] {
                infos.append(cached)
            } else if !unreadable.contains(file) {
                if let info = Self.read(file, startedAt: started) {
                    cache[file] = info
                    infos.append(info)
                } else if started.timeIntervalSinceNow < -120 {
                    unreadable.insert(file)
                }
            }
        }
        cache = cache.filter { seen.contains($0.key) }
        unreadable.formIntersection(seen)
        return infos
    }

    /// `nil` while the job message is still being written.
    private static func read(_ file: URL, startedAt: Date) -> WorkerLogInfo? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let head = String(decoding: (try? handle.read(upToCount: 1024 * 1024)) ?? Data(), as: UTF8.self)

        guard let name = head.firstMatch(of: jobName).map({ unescape(String($0.1)) }),
              let repo = head.firstMatch(of: repository).map({ String($0.1) }),
              let run = head.firstMatch(of: runID).map({ String($0.1) }) else { return nil }
        let server = head.firstMatch(of: serverURL).map { String($0.1) } ?? "https://github.com"
        let check = head.firstMatch(of: checkRunID).map { "/job/\($0.1)" } ?? ""

        guard let url = URL(string: "\(server)/\(repo)/actions/runs/\(run)\(check)") else { return nil }
        return WorkerLogInfo(startedAt: startedAt, jobName: name, url: url, repo: String(repo.split(separator: "/").last ?? Substring(repo)))
    }

    private static func unescape(_ json: String) -> String {
        let data = Data("\"\(json)\"".utf8)
        return (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) as? String ?? json
    }
}
