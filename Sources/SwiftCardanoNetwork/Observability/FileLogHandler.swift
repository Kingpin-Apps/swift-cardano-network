import Foundation
import Logging

/// A `LogHandler` that appends formatted log lines to a file on disk.
///
/// Multiple `FileLogHandler` copies that share the same underlying file coordinate writes
/// through a single thread-safe writer, preserving value semantics for `metadata` and
/// `logLevel` while ensuring no interleaving of concurrent log entries.
public struct FileLogHandler: LogHandler, @unchecked Sendable {
    public var metadata: Logger.Metadata = [:]
    public var logLevel: Logger.Level = .info
    public var metadataProvider: Logger.MetadataProvider?

    private let label: String
    /// Shared, reference-typed writer so copies of this handler all go to the same file.
    private let writer: FileWriter

    /// Create a handler that writes to `fileURL`, creating the file if it does not exist.
    public init(label: String, fileURL: URL) throws {
        self.label = label
        self.writer = try FileWriter(url: fileURL)
    }

    public func log(event: LogEvent) {
        let merged = self.metadata.merging(event.metadata ?? [:]) { _, new in new }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        var line = "\(timestamp) \(event.level.rawValue.uppercased()) [\(label)] \(event.message)"
        if !merged.isEmpty {
            line += " \(merged)"
        }
        line += "\n"
        writer.write(line)
    }

    public subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }
}

// MARK: - FileWriter

extension FileLogHandler {
    /// Thread-safe coordinator for a single open log file.
    fileprivate final class FileWriter: @unchecked Sendable {
        private let fileHandle: FileHandle
        private let lock = NSLock()

        init(url: URL) throws {
            if !FileManager.default.fileExists(atPath: url.path) {
                guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            self.fileHandle = try FileHandle(forWritingTo: url)
            fileHandle.seekToEndOfFile()
        }

        func write(_ text: String) {
            lock.lock()
            defer { lock.unlock() }
            fileHandle.write(Data(text.utf8))
        }

        deinit {
            try? fileHandle.close()
        }
    }
}
