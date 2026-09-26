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
    /// stderr, exactly once, once the process itself has exited and its pipes have had
    /// `SystemProviderProcess.drainGrace` to reach end of file. Something the process started can keep either
    /// pipe's write end open long after the process itself is gone (a detached child, say), which could hold it
    /// open for as long as it likes; `exit` does not wait on that past the bound, though `line` still delivers
    /// whatever a reader still going reads later.
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

/// A child process with a reader thread per pipe: stdout lines are delivered in order as they arrive, and
/// `exit` is reported once the process itself has exited and its readers have had `drainGrace` to catch up,
/// not once they reach end of file — a reader waits on end of file, which something the process started (a
/// detached child that inherited the pipe, say) can hold open long after the process itself is gone, and
/// `exit` must not hang the caller waiting for that (the same tradeoff 0.2.6 gave `PipeReader` on the v2 path).
final class SystemProviderProcess: ProviderProcess, @unchecked Sendable {
    private let process = Process()
    private let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
    private let lock = NSLock()
    private var inputOpen = true

    /// How long `exit` waits for the stdout/stderr readers once the process itself has exited. Everything it
    /// wrote is in the pipes by then, so a reader needs a moment at most; the same bound `ForegroundProcessRunner`
    /// gives `PipeReader` on the v2 path.
    static let drainGrace: TimeInterval = 2

    func start(_ command: ProviderCommand, line: @escaping (Data) -> Void, exit: @escaping (Int32, String) -> Void) throws {
        process.executableURL = URL(fileURLWithPath: command.arguments[0])
        process.arguments = Array(command.arguments.dropFirst())
        process.currentDirectoryURL = command.workingDirectory
        process.environment = ProviderService.subscriptionEnvironment(from: ProcessInfo.processInfo.environment)
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try process.run()
        let group = DispatchGroup()
        let tailLock = NSLock()
        var tail = Data()
        group.enter()
        Thread.detachNewThread { [stdout] in
            // Raw `read()` on the descriptor, incrementally and in a fixed-size buffer, not
            // `FileHandle.availableData`: a read end closed under a blocked `FileHandle` read raises an
            // Objective-C exception Swift cannot catch, which would take the helper down (`PipeReader`'s own
            // reasoning, on the pipe a long chat session's reply streams over).
            let descriptor = stdout.fileHandleForReading.fileDescriptor
            var readBuffer = [UInt8](repeating: 0, count: 65_536)
            var lineBuffer = Data()
            while true {
                let count = read(descriptor, &readBuffer, readBuffer.count)
                if count > 0 {
                    lineBuffer.append(readBuffer, count: count)
                    while let newline = lineBuffer.firstIndex(of: 0x0A) {
                        let lineData = lineBuffer.subdata(in: lineBuffer.startIndex..<newline)
                        lineBuffer.removeSubrange(lineBuffer.startIndex...newline)
                        if !lineData.isEmpty { line(lineData) }
                    }
                    continue
                }
                if count < 0 && errno == EINTR { continue }
                break
            }
            if !lineBuffer.isEmpty { line(lineBuffer) }
            group.leave()
        }
        group.enter()
        Thread.detachNewThread { [stderr] in
            let descriptor = stderr.fileHandleForReading.fileDescriptor
            var readBuffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                let count = read(descriptor, &readBuffer, readBuffer.count)
                if count > 0 {
                    tailLock.lock()
                    tail.append(readBuffer, count: count)
                    if tail.count > 16_384 { tail = tail.suffix(8_192) }
                    tailLock.unlock()
                    continue
                }
                if count < 0 && errno == EINTR { continue }
                break
            }
            group.leave()
        }
        Thread.detachNewThread { [process] in
            process.waitUntilExit()
            // Bounded, not forever: past this, whichever reader has not reached end of file is waiting on
            // something the process left running with the pipe open, which is not this call's to wait for.
            _ = group.wait(timeout: .now() + Self.drainGrace)
            tailLock.lock(); let tailSnapshot = tail; tailLock.unlock()
            exit(process.terminationStatus, ProviderOutput.tail(String(decoding: tailSnapshot, as: UTF8.self)))
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
