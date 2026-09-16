import Foundation
import IrisBridgeCore

let usage = "Usage: iris-bridge [serve|pair|status|devices|revoke <id>|inbox [clear-decided]|mcp|install-agent --binary <path>|uninstall|version]"

func complain(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// Everything a user typed wrong exits 2 with the reason on stderr, so a script can tell "you asked wrong"
/// (2) from "the helper could not do it" (1).
func refuse(_ message: String) -> Never {
    complain(message)
    exit(2)
}

func serve(root: String?, port: UInt16, bonjour: Bool) throws {
    var paths = BridgePaths.standard
    if let root { let url = URL(fileURLWithPath: root); paths = BridgePaths(root: url, logs: url.appendingPathComponent("logs")) }
    try paths.prepare()
    let log = BridgeLog(file: paths.logFile)
    let identity = try CertificateManager.load(paths: paths)
    // A missing file is the first run; a short or blank one is a truncated write, a hand-edited file, or a
    // half-finished install. Either way it cannot authenticate anything, and accepting it would make
    // `/admin/*` answer to an empty bearer, so it is replaced rather than read.
    let storedAdminToken = (try? String(contentsOf: paths.adminToken, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if storedAdminToken.count < 32 { try BridgePaths.writePrivate(Data(DeviceStore.randomToken().utf8), to: paths.adminToken) }
    let adminToken = try String(contentsOf: paths.adminToken, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    let devices = DeviceStore(file: paths.devices)
    let pairing = PairingCodeStore()
    let inbox = InboxStore(file: paths.inbox)
    // Decided submissions are history, not a queue, and nothing else ever deletes them: without this a Mac
    // that runs for a year keeps every approval it ever made in the file the app downloads.
    if let removed = try? inbox.pruneDecided(olderThan: 30 * 24 * 60 * 60), removed > 0 {
        log.info("pruned \(removed) decided submissions older than 30 days")
    }
    let context = ContextStore(file: paths.context)
    let router = Router(fingerprint: identity.fingerprint, hostName: HostName.computerName(), adminToken: adminToken, devices: devices, pairing: pairing,
                        inbox: inbox, context: context, generator: LiveGenerator(), log: log)
    let server = try BridgeServer(port: port, identity: identity, router: router, serviceName: HostName.computerName(), advertise: bonjour, log: log)
    signal(SIGPIPE, SIG_IGN)
    try server.start()
    print("Iris Bridge \(BridgeVersion.current) is running on port \(server.actualPort ?? port).")
    if devices.all.isEmpty {
        // Under launchd, stdout is a log file: a code printed here would sit on disk for anyone who can read
        // the log, long after it stopped being useful. A code is only issued when a person is watching.
        if isatty(1) != 0 {
            let issued = pairing.issue()
            print("\nPairing code: \(issued.code)   (valid 10 minutes)\nOpen Iris, choose \"\(HostName.computerName())\" under Macs nearby, and enter the code.\n")
        } else {
            print("No devices are paired yet. Run `iris-bridge pair` to get a code.")
        }
    }
    // Under launchd stdout is a file, so these lines sit in a block buffer until the process exits — which,
    // for a helper meant to run forever, is never. Flush once here so the log says what happened at startup.
    fflush(stdout)
    dispatchMain()
}

/// A pairing code is read off the screen and typed into a phone, so it gets room of its own and a spaced-out
/// copy: six digits in a row are easy to misread in a wall of Terminal text.
func printPairingCode(_ code: String) {
    let spaced = code.map(String.init).joined(separator: " ")
    print("")
    print("  Pairing code:  \(code)")
    print("                 \(spaced)")
    print("")
    print("  Open Iris, choose \"\(HostName.computerName())\" under Macs nearby, and enter this code.")
    print("  It expires in 10 minutes. Run `iris-bridge pair` for a new one.")
    print("")
}

let line: BridgeCommandLine
let port: UInt16
do {
    line = try BridgeCommandLine.parse(Array(CommandLine.arguments.dropFirst()))
    port = try line.port(default: 48731)
} catch {
    refuse(error.localizedDescription)
}

var paths = BridgePaths.standard
if let root = line.options["--root"] { let url = URL(fileURLWithPath: root); paths = BridgePaths(root: url, logs: url.appendingPathComponent("logs")) }

do {
    switch line.command {
    case "serve":
        try serve(root: line.options["--root"], port: port, bonjour: !line.flags.contains("--no-bonjour"))
    case "pair":
        printPairingCode(try AdminClient(paths: paths, port: port).pairCode().code)
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
        // The id is the first real argument: `revoke --root /tmp/x abc` revokes abc, not --root.
        guard let id = line.positionals.first else { refuse("Usage: iris-bridge revoke <device-id>") }
        print(try AdminClient(paths: paths, port: port).revoke(id) ? "Revoked \(id). That device will ask to reconnect." : "No device with id \(id).")
    case "inbox":
        let client = try AdminClient(paths: paths, port: port)
        if line.positionals.first == "clear-decided" {
            let removed = try client.pruneDecided()
            print(removed == 1 ? "Removed 1 decided submission older than 30 days."
                               : "Removed \(removed) decided submissions older than 30 days.")
        } else if let first = line.positionals.first {
            refuse("Usage: iris-bridge inbox [clear-decided] (I do not know \"\(first)\").")
        } else {
            let waiting = try client.listSubmissions(status: "pending")
            if waiting.isEmpty {
                print("Nothing is waiting. Your agent has not sent anything yet.")
            }
            let now = Date()
            for submission in waiting {
                print("\(submission.id)  \(submission.kind.rawValue)  \(submission.displayTitle)  \(submission.ageText(now: now))")
            }
        }
    case "mcp":
        // stdout belongs to JSON-RPC from here on. Nothing else may print to it, which is why this branch
        // has no `print` of its own and the server writes through the transport.
        let server = MCPServer(client: LoopbackAdminClient(paths: paths, port: port), version: BridgeVersion.current)
        try server.run(transport: StdioMCPTransport())
    case "install-agent":
        guard let typed = line.options["--binary"] else { refuse("Usage: iris-bridge install-agent --binary <path>") }
        // launchd needs an absolute path and will not tell you if the program is missing: it just fails to
        // spawn, over and over, into a log nobody reads. Check here instead.
        let binary = URL(fileURLWithPath: (typed as NSString).expandingTildeInPath).standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: binary) else {
            refuse("There is no file at \(binary). Pass the path to the installed helper, like `iris-bridge install-agent --binary \"$HOME/Library/Application Support/Iris Bridge/bin/iris-bridge\"`.")
        }
        guard FileManager.default.isExecutableFile(atPath: binary) else {
            refuse("\(binary) is not something macOS can run. Check the path, or run `chmod +x \"\(binary)\"`.")
        }
        try LaunchAgent.install(binary: binary)
        print("Iris Bridge will start automatically when you log in.")
    case "uninstall":
        // This deletes a folder tree, and it only ever deletes the one the installer created. Silently
        // ignoring a --root someone typed would be worse than refusing it: they would think they had
        // pointed it somewhere else.
        if line.options["--root"] != nil {
            refuse("uninstall does not take --root; it only removes the standard Iris Bridge installation.")
        }
        let installed = BridgePaths.standard
        let home = FileManager.default.homeDirectoryForCurrentUser
        let installedBinary = installed.root.appendingPathComponent("bin/iris-bridge")
        // The LaunchAgent goes first and unconditionally: launchd state registered under our label is ours
        // whatever the support folder looks like. An orphan — folder deleted by hand, or an install that
        // failed halfway — is exactly the case a user runs `uninstall` to clean up, and a folder check in
        // front of the bootout would leave a helper running that nothing can stop.
        try LaunchAgent.uninstall()
        // The folder is a different matter: this deletes a tree, so it only ever deletes one that still
        // carries our marker files. Anything else is left alone and said so, which is a successful cleanup
        // of an orphan, not a failure.
        guard LaunchAgent.looksLikeBridgeFolder(installed.root) else {
            print("Stopped the Iris Bridge background helper. The support folder at \(installed.root.path) was missing or did not look like an Iris Bridge folder, so it was left alone.")
            exit(0)
        }
        try? FileManager.default.removeItem(at: installed.root)
        // The convenience symlink, but only while it still points at the copy we just removed. Never
        // argv[0]: that is whatever binary the user happened to run, which may be a build of their own.
        let link = home.appendingPathComponent(".local/bin/iris-bridge")
        if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) {
            let target = destination.hasPrefix("/") ? URL(fileURLWithPath: destination)
                                                    : link.deletingLastPathComponent().appendingPathComponent(destination)
            if target.standardizedFileURL.path == installedBinary.standardizedFileURL.path {
                try? FileManager.default.removeItem(at: link)
            }
        }
        print("Iris Bridge removed. Claude Code and Codex were left installed.")
    case "--version", "version":
        print("iris-bridge \(BridgeVersion.current)")
    case "--help", "-h", "help":
        print(usage)
    default:
        complain("iris-bridge: \(line.command) is not a command I know.")
        refuse(usage)
    }
} catch {
    complain(error.localizedDescription)
    exit(1)
}
