import XCTest
@testable import IrisBridgeCore

/// A handler that answers hello and echoes what it receives, so the hub is tested on its own.
private final class EchoHandler: StreamHandler {
    var received: [AppMessage] = []
    var disconnects = 0
    weak var hub: StreamHub?
    func helloOK(for device: PairedDevice) -> JSONValue { HelperMessage.helloOK(helperVersion: "test", capabilities: ["v3"], health: ["device": .string(device.name)]) }
    func connected(device: PairedDevice, cursors: [String: Int], send: @escaping (JSONValue) -> Void) {
        send(["type": "replayed", "cursors": .number(Double(cursors.count))])
    }
    func received(_ message: AppMessage, from device: PairedDevice) {
        received.append(message)
        hub?.broadcast(["type": "echo"])
    }
    func disconnected(device: PairedDevice) { disconnects += 1 }
}

final class StreamHubTests: XCTestCase {
    private var live: LiveTestServer!
    private var handler: EchoHandler!

    override func setUpWithError() throws {
        live = try LiveTestServer(helloTimeout: 1)
        handler = EchoHandler()
        handler.hub = live.hub
        live.hub.handler = handler
    }

    private func open() -> URLSessionWebSocketTask {
        let task = live.session().webSocketTask(with: live.streamURL())
        task.resume()
        return task
    }

    func testAPairedDeviceGetsHelloOKThenItsReplayThenLiveMessages() {
        let task = open()
        sendText(task, #"{"type":"hello","deviceToken":"\#(live.token)","appVersion":"test","protocol":3,"cursors":{"a":1}}"#)
        let greeting = receiveMessages(task, count: 2)
        XCTAssertEqual(greeting.first?["type"], "hello.ok")
        XCTAssertEqual(greeting.first?["health"]?["device"], "Test phone")
        XCTAssertEqual(greeting.last?["type"], "replayed")
        XCTAssertEqual(greeting.last?["cursors"]?.intValue, 1)
        XCTAssertTrue(live.hub.hasClients)
        sendText(task, #"{"type":"turn.cancel","threadId":"8B2F4C1E-7A0D-4E55-9C3B-2F1D0E6A9B77","turnId":"t1"}"#)
        XCTAssertEqual(receiveMessages(task, count: 1).first?["type"], "echo")
        XCTAssertEqual(handler.received, [.turnCancel(.init(threadId: "8B2F4C1E-7A0D-4E55-9C3B-2F1D0E6A9B77", turnId: "t1"))])
        task.cancel(with: .normalClosure, reason: nil)
    }

    func testAnUnknownTokenIsClosedWith4401AndLearnsNothing() {
        let task = open()
        sendText(task, #"{"type":"hello","deviceToken":"not-a-device","protocol":3}"#)
        XCTAssertEqual(closeCode(task), 4401)
        XCTAssertFalse(live.hub.hasClients)
    }

    func testTheFirstMessageMustBeAHelloForThisProtocolAndArriveInTime() {
        let notHello = open()
        sendText(notHello, #"{"type":"thread.open","threadId":"x","provider":"claude"}"#)
        XCTAssertEqual(closeCode(notHello), 4400)
        let oldProtocol = open()
        sendText(oldProtocol, #"{"type":"hello","deviceToken":"\#(live.token)","protocol":2}"#)
        XCTAssertEqual(closeCode(oldProtocol), 4426)
        let silent = open()
        XCTAssertEqual(closeCode(silent, timeout: 4), 4408)
    }

    func testRevokingTheDeviceClosesItsOpenStream() throws {
        let task = open()
        sendText(task, #"{"type":"hello","deviceToken":"\#(live.token)","protocol":3}"#)
        XCTAssertEqual(receiveMessages(task, count: 2).count, 2)
        for device in live.devices.all { _ = try live.devices.revoke(id: device.id) }
        live.hub.broadcast(["type": "health.changed"])
        XCTAssertEqual(closeCode(task), 4401)
    }

    /// The v2 endpoints share the port with the stream and keep answering plain HTTP.
    func testPlainHTTPStillWorksOnTheSamePort() throws {
        let done = expectation(description: "status")
        var status: [String: Any] = [:]
        live.session().dataTask(with: URL(string: "https://127.0.0.1:\(live.port)/status")!) { data, _, _ in
            status = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 5)
        XCTAssertEqual(status["hostName"] as? String, "Test Mac")
    }
}
