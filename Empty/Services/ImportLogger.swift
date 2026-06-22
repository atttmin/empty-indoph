//
//  ImportLogger.swift
//  Empty
//
//  Writes import diagnostics to a file in Documents so users without
//  a Mac can read them.
//

import Foundation

/// Simple file-backed logger for the import flow.
nonisolated enum ImportLogger {
    private static var logFile: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appending(path: "import-log.txt")
    }()

    /// Synchronous file write — guaranteed to land before the function returns.
    static func write(_ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] \(message)\n"
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
