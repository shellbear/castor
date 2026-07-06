@preconcurrency import Foundation

/// A long-running ffmpeg process. stderr is drained continuously (a full pipe
/// buffer would stall the encoder) into a capped tail kept for diagnostics.
actor FFmpegProcess {
    private var process: Process?
    private let stderrTail = TailBuffer()

    var isRunning: Bool {
        process?.isRunning ?? false
    }

    var lastErrorOutput: String {
        stderrTail.text
    }

    func start(tool: URL, arguments: [String]) throws {
        terminate()
        stderrTail.reset()

        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice

        let stderr = Pipe()
        process.standardError = stderr
        let tail = stderrTail
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                tail.append(data)
            }
        }

        try process.run()
        self.process = process
    }

    func terminate() {
        guard let process, process.isRunning else {
            self.process = nil
            return
        }
        process.terminate()
        self.process = nil
    }
}

/// Thread-safe capped buffer for the stderr tail.
private final class TailBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let cap = 8192

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
        if data.count > cap {
            data.removeFirst(data.count - cap)
        }
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        data.removeAll()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
