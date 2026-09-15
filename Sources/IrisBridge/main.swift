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
let port = UInt16(option("--port") ?? "48731") ?? 48731
var paths = BridgePaths.standard
if let root = option("--root") { let url = URL(fileURLWithPath: root); paths = BridgePaths(root: url, logs: url.appendingPathComponent("logs")) }
do {
    switch command {
    case "serve": try serve(root: option("--root"), port: port, bonjour: !args.contains("--no-bonjour"))
    case "pair":
        let issued = try AdminClient(paths: paths, port: port).pairCode()
        print("\n  Pairing code:  \(issued.code)\n\n  Open Iris, choose \"\(HostName.computerName())\" under Macs nearby, and enter this code.\n  It expires in 10 minutes. Run `iris-bridge pair` for a new one.\n")
    case "status":
        let s = try AdminClient(paths: paths, port: port).status()
        let providers = s["providers"] as? [String: [String: Any]] ?? [:]
        print("Iris Bridge \(s["helperVersion"] ?? "?") on \(s["hostName"] ?? "?") (port \(port))")
        for name in ["claude", "codex"] { print("  \(name): \((providers[name]?["ready"] as? Bool) == true ? "signed in" : "not signed in") — \(providers[name]?["message"] ?? "")") }
        print("  paired devices: \(DeviceStore(file: paths.devices).all.count)")
    case "devices":
        let list = try AdminClient(paths: paths, port: port).devices()
        if list.isEmpty { print("No paired devices. Run `iris-bridge pair`.") }
        for d in list { print("\(d["id"] ?? "")  \(d["name"] ?? "")  (\(d["platform"] ?? ""))  paired \(d["pairedAt"] ?? "")  last seen \(d["lastSeenAt"] ?? "")") }
    case "revoke":
        guard let id = args.first else { print("Usage: iris-bridge revoke <device-id>"); exit(2) }
        print(try AdminClient(paths: paths, port: port).revoke(id) ? "Revoked \(id). That device will ask to reconnect." : "No device with id \(id).")
    case "install-agent":
        guard let binary = option("--binary") else { print("Usage: iris-bridge install-agent --binary <path>"); exit(2) }
        try LaunchAgent.install(binary: binary); print("Iris Bridge will start automatically when you log in.")
    case "uninstall":
        try LaunchAgent.uninstall()
        try? FileManager.default.removeItem(at: paths.root)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath())
        print("Iris Bridge removed. Claude Code and Codex were left installed.")
    case "--version", "version": print("iris-bridge \(BridgeVersion.current)")
    default: print("Usage: iris-bridge [serve|pair|status|devices|revoke <id>|uninstall|version]"); exit(2)
    }
} catch { FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8)); exit(1) }
