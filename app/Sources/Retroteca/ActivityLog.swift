import Foundation

/// `~/Library/Logs/Retroteca/activity.log`: one line per thing Retroteca did, to find out later what happened.
enum ActivityLog {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Retroteca", isDirectory: true)
    }

    static func write(_ line: String) {
        guard !line.isEmpty else { return }
        let url = directory.appendingPathComponent("activity.log")
        let text = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? Data(text.utf8).write(to: url)
        }
        log.info("\(line, privacy: .public)")
    }
}
