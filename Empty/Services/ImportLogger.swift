//
//  ImportLogger.swift
//  Empty
//
//  Writes import diagnostics to a file in Documents so users without
//  a Mac can read them. Tap the 朱 button 3× to open the log viewer.
//

import Foundation
import OSLog

/// Simple file-backed logger for the import flow.
nonisolated enum ImportLogger {
    private static let logFile = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appending(path: "import-log.txt")
    }()
    private static let queue = DispatchQueue(label: "import-logger")

    static func write(_ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: logFile.path) {
                if let handle = try? FileHandle(forWritingTo: logFile) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    try? handle.close()
                }
            } else {
                try? data.write(to: logFile)
            }
        }
    }

    /// Preview last N lines.
    static func preview(lineCount: Int = 30) -> String {
        guard let data = try? Data(contentsOf: logFile),
              let text = String(data: data, encoding: .utf8) else {
            return "（无日志）"
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(lineCount).joined(separator: "\n")
    }

    /// Clear log file.
    static func clear() {
        queue.async {
            try? FileManager.default.removeItem(at: logFile)
        }
    }
}
