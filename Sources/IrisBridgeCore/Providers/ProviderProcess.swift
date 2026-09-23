import Foundation

/// One provider CLI run: what to start, where, and what to write to it first.
public struct ProviderCommand: Equatable {
    public var arguments: [String]
    public var workingDirectory: URL
    /// Written to stdin, which is then closed (Codex reads its prompt this way). Nil keeps stdin open for
    /// stream-json messages (Claude).
    public var input: Data?

    public init(arguments: [String], workingDirectory: URL, input: Data? = nil) {
        self.arguments = arguments; self.workingDirectory = workingDirectory; self.input = input
    }
}

/// A running provider CLI.
public protocol ProviderProcess: AnyObject {
    /// One line of JSON to stdin; the newline is added. Ignored once the process is gone.
    func write(_ line: Data)
    /// Closes stdin: a stream-json session finishes what it is doing and exits.
    func closeInput()
    /// SIGTERM to the process group, SIGKILL three seconds later if it is still there.
    func terminate()
}

/// Starts provider CLIs. `SystemProcessLauncher` is the real one; tests replay recorded output instead.
public protocol ProcessLauncher: AnyObject {
    /// `line` gets each stdout line in order; `exit` gets the exit status and the last 2,000 characters of
    /// stderr, exactly once, after the last line.
    func launch(_ command: ProviderCommand, line: @escaping (Data) -> Void,
                exit: @escaping (Int32, String) -> Void) throws -> ProviderProcess
}

public final class SystemProcessLauncher: ProcessLauncher {
    public init() {}

    public func launch(_ command: ProviderCommand, line: @escaping (Data) -> Void,
                       exit: @escaping (Int32, String) -> Void) throws -> ProviderProcess {
        let process = SystemProviderProcess()
        try process.start(command, line: line, exit: exit)
        return process
    }
}

/// A child process with a reader thread per pipe: stdout lines are delivered in order and all of them before
/// `exit`, which a readability handler cannot promise.
final class SystemProviderProcess: ProviderProcess, @unchecked Sendable {
    private let process = Process()
    private let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
    private let lock = NSLock()
    private var inputOpen = true

    func start(_ command: ProviderCommand, line: @escaping (Data) -> Void, exit: @escaping (Int32, String) -> Void) throws {
        process.executableURL = URL(fileURLWithPath: command.arguments[0])
        process.arguments = Array(command.arguments.dropFirst())
        process.currentDirectoryURL = command.workingDirectory
        process.environment = ProviderService.subscriptionEnvironment(from: ProcessInfo.processInfo.environment)
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try process.run()
        let group = DispatchGroup()
        var tail = Data()
        group.enter()
        Thread.detachNewThread { [stdout] in
            var buffer = Data()
            while true {
                let chunk = stdout.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer.subdata(in: buffer.startIndex..<newline)
                    buffer.removeSubrange(buffer.startIndex...newline)
                    if !lineData.isEmpty { line(lineData) }
                }
            }
            if !buffer.isEmpty { line(buffer) }
            group.leave()
        }
        group.enter()
        Thread.detachNewThread { [stderr] in
            while true {
                let chunk = stderr.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                tail.append(chunk)
                if tail.count > 16_384 { tail = tail.suffix(8_192) }
            }
            group.leave()
        }
        Thread.detachNewThread { [process] in
            process.waitUntilExit()
            group.wait()
            exit(process.terminationStatus, ProviderOutput.tail(String(decoding: tail, as: UTF8.self)))
        }
        if let input = command.input {
            try? stdin.fileHandleForWriting.write(contentsOf: input)
            closeInput()
        }
    }

    func write(_ line: Data) {
        lock.lock(); defer { lock.unlock() }
        guard inputOpen else { return }
        try? stdin.fileHandleForWriting.write(contentsOf: line + Data([0x0A]))
    }

    func closeInput() {
        lock.lock(); defer { lock.unlock() }
        guard inputOpen else { return }
        inputOpen = false
        try? stdin.fileHandleForWriting.close()
    }

    func terminate() {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        kill(-pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [process] in
            if process.isRunning { kill(-pid, SIGKILL) }
        }
    }
}
