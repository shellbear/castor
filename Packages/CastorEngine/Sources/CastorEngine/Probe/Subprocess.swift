@preconcurrency import Foundation

/// Runs short-lived command line tools to completion (probing, extraction).
/// Long-running encodes are managed by `FFmpegSession` instead.
enum Subprocess {
    struct Failure: Error, CustomStringConvertible {
        let executable: String
        let status: Int32
        let stderr: String
        var description: String { "\(executable) exited with status \(status): \(stderr)" }
    }

    @discardableResult
    static func run(_ executable: URL, arguments: [String]) async throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let outHandle = stdout.fileHandleForReading
        let errHandle = stderr.fileHandleForReading

        // Drain both pipes concurrently so a full pipe buffer can never block
        // the child (ffprobe JSON easily exceeds the 64 KB pipe buffer).
        let outTask = Task.detached { (try? outHandle.readToEnd()) ?? Data() }
        let errTask = Task.detached { (try? errHandle.readToEnd()) ?? Data() }

        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { _ in cont.resume() }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    cont.resume(throwing: error)
                }
            }
        } catch {
            // The child never spawned: close our write ends so the drain tasks
            // see EOF instead of blocking forever.
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForWriting.close()
            _ = await outTask.value
            _ = await errTask.value
            throw error
        }

        let output = await outTask.value
        let errOutput = await errTask.value

        guard process.terminationStatus == 0 else {
            throw Failure(
                executable: executable.lastPathComponent,
                status: process.terminationStatus,
                stderr: String(data: errOutput, encoding: .utf8) ?? ""
            )
        }
        return output
    }
}
