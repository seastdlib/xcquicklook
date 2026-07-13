import Foundation
import os

/// Debug-build diagnostics: os_log for Console plus an append-only file in the
/// process's temporary directory (the appex's container tmp), where dev
/// tooling can read it. Release builds log nothing — previewed filenames are
/// user data and don't belong in the unified log.
nonisolated enum DebugLog {
    #if DEBUG
    private static let logger = Logger(subsystem: "com.seastdlib.xcquicklook", category: "preview")
    #endif

    static func log(_ message: String) {
        #if DEBUG
        logger.log("\(message, privacy: .public)")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("xcql-debug.log")
        let line = "\(Date()) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
        #endif
    }
}
