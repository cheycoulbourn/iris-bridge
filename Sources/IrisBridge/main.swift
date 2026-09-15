import Foundation
import IrisBridgeCore

func serve(root: String?, port: UInt16, bonjour: Bool) throws {
    var paths = BridgePaths.standard
    if let root { let url = URL(fileURLWithPath: root); paths = BridgePaths(root: url, logs: url.appendingPathComponent("logs")) }
    try paths.prepare()
    let log = BridgeLog(file: paths.logFile)
    let identity = try CertificateManager.load(paths: paths)
    if !FileManager.default.fileExists(atPath: paths.adminToken.path) { try BridgePaths.writePrivate(Data(DeviceStore.randomToken().utf8), to: paths.adminToken) }
    let adminToken = try String(contentsOf: paths.adminToken, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    let devices = DeviceStore(file: paths.devices)
    let pairing = PairingCodeStore()
    let router = Router(fingerprint: identity.fingerprint, hostName: HostName.computerName(), adminToken: adminToken, devices: devices, pairing: pairing, generator: LiveGenerator(), log: log)
    let server = try BridgeServer(port: port, identity: identity, router: router, serviceName: HostName.computerName(), advertise: bonjour, log: log)
    signal(SIGPIPE, SIG_IGN)
    try server.start()
    print("Iris Bridge \(BridgeVersion.current) is running on port \(server.actualPort ?? port).")
    if devices.all.isEmpty {
        let issued = pairing.issue()
        print("\nPairing code: \(issued.code)   (valid 10 minutes)\nOpen Iris, choose \"\(HostName.computerName())\" under Macs nearby, and enter the code.\n")
    }
    dispatchMain()
}

var args = Array(CommandLine.arguments.dropFirst())
let command = args.isEmpty ? "serve" : args.removeFirst()
func option(_ name: String) -> String? { guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }; return args[i + 1] }
do {
    switch command {
    case "serve": try serve(root: option("--root"), port: UInt16(option("--port") ?? "48731") ?? 48731, bonjour: !args.contains("--no-bonjour"))
    case "--version", "version": print("iris-bridge \(BridgeVersion.current)")
    default: print("Unknown command: \(command)"); exit(2)
    }
} catch { FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8)); exit(1) }
