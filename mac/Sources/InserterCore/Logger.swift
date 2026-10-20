import Foundation

/// Appends timestamped lines to a file (and optionally stderr) with simple size-based rotation.
/// Callers only ever pass metadata; inserted text is never handed to a logger.
public final class FileLogger: RequestLogger {
    private let url: URL?
    private let echo: Bool
    private let maxBytes: Int
    private let lock = NSLock()
    private let formatter: ISO8601DateFormatter = ISO8601DateFormatter()

    public init(file: URL?, echoToStderr: Bool, maxBytes: Int = 2 * 1024 * 1024) {
        self.url = file
        self.echo = echoToStderr
        self.maxBytes = maxBytes
    }

    public func log(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        lock.lock(); defer { lock.unlock() }
        if echo { FileHandle.standardError.write(Data(line.utf8)) }
        guard let url = url else { return }
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxBytes {
            let old = url.appendingPathExtension("1")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        }
    }
}
