import Foundation

// The runner service's stdout log, where the listener prints:
//   2026-10-25 13:40:00Z: Running job: Build and Test iOS App
//   2026-10-25 13:52:10Z: Job Build and Test iOS App completed with result: Succeeded

struct JobRun: Identifiable, Equatable, Sendable {
    let id: Int
    let name: String
    let startedAt: Date
    var finishedAt: Date?
    var result: String?

    var isFinished: Bool { result != nil }
}

enum LogParser {
    private static let timestamped = #/^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}Z): (.*)$/#
    private static let completed = #/^Job (.+) completed with result: (\w+)$/#

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss'Z'"
        return formatter
    }()

    static func parse(_ log: String) -> [JobRun] {
        var jobs: [JobRun] = []
        for line in log.split(whereSeparator: \.isNewline).map(String.init) {
            // runsvc.sh prints this untimestamped line each time the listener
            // (re)starts; a job still open at that point died with it.
            if line.hasPrefix("Starting Runner listener") {
                for index in jobs.indices where !jobs[index].isFinished {
                    jobs[index].result = "Interrupted"
                }
                continue
            }
            guard let match = line.wholeMatch(of: timestamped),
                  let date = dateFormatter.date(from: String(match.1)) else { continue }
            let message = String(match.2)

            if message.hasPrefix("Running job: ") {
                let name = String(message.dropFirst("Running job: ".count))
                jobs.append(JobRun(id: jobs.count, name: name, startedAt: date))
            } else if let done = message.wholeMatch(of: completed),
                      let index = jobs.lastIndex(where: { $0.name == String(done.1) && !$0.isFinished }) {
                jobs[index].finishedAt = date
                jobs[index].result = String(done.2)
            }
        }
        return jobs
    }

    /// Only the tail of the log matters; it grows by a few lines per job.
    static func readTail(of url: URL, maxBytes: UInt64 = 512 * 1024) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: size > maxBytes ? size - maxBytes : 0)
        let data = try handle.readToEnd() ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
