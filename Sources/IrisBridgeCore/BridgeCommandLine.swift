import Foundation

/// The helper's command line, parsed once and strictly.
///
/// Anything ambiguous is refused rather than quietly defaulted: a `--port` that is not a number used to fall
/// back to 48731 and talk to the wrong helper, and `iris-bridge revoke --root /tmp/x abc` used to try to
/// revoke a device called `--root`. An option's value is never mistaken for a positional argument.
public struct BridgeCommandLine: Equatable {
    /// Options that consume the next argument as their value.
    public static let valueOptions: Set<String> = ["--root", "--port", "--binary"]
    /// Valueless switches the helper understands. Anything else starting with `-` is a typo, and a typo that
    /// is quietly ignored is worse than an error: `status --prot 48797` would talk to the default port.
    public static let knownFlags: Set<String> = ["--no-bonjour"]

    /// The subcommand, or `serve` when the user typed nothing.
    public let command: String
    /// Arguments that are neither a flag nor a flag's value, in the order typed. `revoke` reads the first.
    public let positionals: [String]
    /// Values of the options in `valueOptions`, keyed by the option including its dashes.
    public let options: [String: String]
    /// Valueless switches such as `--no-bonjour`, keyed by the switch including its dashes.
    public let flags: Set<String>

    public init(command: String, positionals: [String] = [], options: [String: String] = [:], flags: Set<String> = []) {
        self.command = command
        self.positionals = positionals
        self.options = options
        self.flags = flags
    }

    public static func parse(_ arguments: [String], defaultCommand: String = "serve") throws -> BridgeCommandLine {
        var rest = arguments
        let command = rest.isEmpty ? defaultCommand : rest.removeFirst()
        var positionals: [String] = []
        var options: [String: String] = [:]
        var flags: Set<String> = []
        var index = 0
        while index < rest.count {
            let token = rest[index]
            if token.hasPrefix("--"), let equals = token.firstIndex(of: "="), valueOptions.contains(String(token[token.startIndex..<equals])) {
                let name = String(token[token.startIndex..<equals])
                let value = String(token[token.index(after: equals)...])
                guard !value.isEmpty else { throw needsValue(name) }
                options[name] = value
                index += 1
            } else if valueOptions.contains(token) {
                // A value that is itself an option means the user left this one empty, e.g. `--root --no-bonjour`.
                guard index + 1 < rest.count, !rest[index + 1].hasPrefix("--") else { throw needsValue(token) }
                options[token] = rest[index + 1]
                index += 2
            } else if token.hasPrefix("-"), token != "-" {
                guard knownFlags.contains(token) else { throw BridgeError.message("iris-bridge does not understand \(token).") }
                flags.insert(token)
                index += 1
            } else {
                positionals.append(token)
                index += 1
            }
        }
        return BridgeCommandLine(command: command, positionals: positionals, options: options, flags: flags)
    }

    /// The port to talk to, or `fallback` when `--port` was not given. Throws rather than silently falling
    /// back, so a typo cannot point a subcommand at the wrong helper.
    public func port(default fallback: UInt16) throws -> UInt16 {
        guard let text = options["--port"] else { return fallback }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let value = UInt16(trimmed), value > 0 else {
            throw BridgeError.message("--port must be a whole number between 1 and 65535 (got \"\(text)\").")
        }
        return value
    }

    private static func needsValue(_ name: String) -> Error {
        let example: String
        switch name {
        case "--port": example = "48731"
        case "--binary": example = "\"$HOME/Library/Application Support/Iris Bridge/bin/iris-bridge\""
        default: example = "/path/to/folder"
        }
        return BridgeError.message("\(name) needs a value, like `\(name) \(example)`.")
    }
}
