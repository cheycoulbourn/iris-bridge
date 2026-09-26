import XCTest
@testable import IrisBridgeCore

/// The real launcher, with `/bin/sh` standing in for a provider CLI.
final class SystemProcessLauncherTests: XCTestCase {
    private func run(_ script: String, input: Data? = nil, afterLaunch: (ProviderProcess) -> Void = { _ in }) throws -> (lines: [String], status: Int32, stderr: String) {
        let done = expectation(description: "exit")
        let lock = NSLock()
        var lines: [String] = [], status: Int32 = -1, stderr = ""
        let process = try SystemProcessLauncher().launch(
            ProviderCommand(arguments: ["/bin/sh", "-c", script], workingDirectory: FileManager.default.temporaryDirectory, input: input),
            line: { data in lock.lock(); lines.append(String(decoding: data, as: UTF8.self)); lock.unlock() },
            exit: { code, tail in status = code; stderr = tail; done.fulfill() })
        afterLaunch(process)
        wait(for: [done], timeout: 10)
        lock.lock(); defer { lock.unlock() }
        return (lines, status, stderr)
    }

    func testEveryLineArrivesInOrderBeforeTheExit() throws {
        let result = try run("i=1; while [ $i -le 200 ]; do echo \"{\\\"n\\\":$i}\"; i=$((i+1)); done; printf 'no newline'; echo oops >&2; exit 3")
        XCTAssertEqual(result.lines.count, 201)
        XCTAssertEqual(result.lines.first, #"{"n":1}"#)
        XCTAssertEqual(result.lines[199], #"{"n":200}"#)
        XCTAssertEqual(result.lines.last, "no newline")
        XCTAssertEqual(result.status, 3)
        XCTAssertEqual(result.stderr, "oops")
    }

    func testInputIsWrittenAndClosedAndLinesCanBeWrittenLater() throws {
        XCTAssertEqual(try run("cat", input: Data("prompt text".utf8)).lines, ["prompt text"])
        let echoed = try run("read line; echo \"got $line\"") { process in
            process.write(Data("hello".utf8))
            process.closeInput()
        }
        XCTAssertEqual(echoed.lines, ["got hello"])
    }

    /// A long-running v3 chat session's CLI can exit while something it started (an MCP server it spawned and
    /// left behind, say) keeps holding the write end of stdout open. `exit` must still be reported, bounded by
    /// `SystemProviderProcess.drainGrace`, not withheld until that leftover process's own pipe reaches end of
    /// file — which, before this fix, blocked `group.wait()` forever and never called `exit` at all.
    func testExitIsReportedEvenWhenSomethingTheProcessStartedKeepsItsPipeOpen() throws {
        let start = Date()
        let result = try run("(sleep 5 &) ; echo done")
        XCTAssertEqual(result.lines, ["done"])
        XCTAssertEqual(result.status, 0)
        XCTAssertLessThan(Date().timeIntervalSince(start), SystemProviderProcess.drainGrace + 3)
    }

    func testTerminateStopsTheWholeProcessGroup() throws {
        let result = try run("sleep 30 & wait") { process in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { process.terminate() }
        }
        XCTAssertEqual(result.status, 15)
    }

    func testTheProviderEnvironmentHasNoAPIKeys() throws {
        setenv("ANTHROPIC_API_KEY", "should-not-leak", 1)
        defer { unsetenv("ANTHROPIC_API_KEY") }
        XCTAssertEqual(try run("echo \"[${ANTHROPIC_API_KEY:-none}]\"").lines, ["[none]"])
    }
}
