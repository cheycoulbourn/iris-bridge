import Foundation

/// A same-Mac request still needs the person at the Mac to approve its new device token. The script is
/// fixed: no device name, hostname, or other requester-controlled text can become AppleScript source.
public enum LocalPairingApproval {
    static let script = """
    on run argv
        set confirmation to item 1 of argv
        set answer to display dialog ("In Iris, check that the connection number is " & confirmation & ". Only allow if it matches.") with title "Connect Iris" buttons {"Cancel", "Allow"} default button "Cancel" cancel button "Cancel" giving up after 60
        if gave up of answer then return "denied"
        if button returned of answer is "Allow" then return "approved"
        return "denied"
    end run
    """

    static func valid(_ confirmation: String) -> Bool {
        confirmation.utf8.count == 32 && confirmation.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }

    public static func formatted(_ confirmation: String) -> String {
        let characters = Array(confirmation.prefix(12).uppercased())
        return stride(from: 0, to: characters.count, by: 4).map { String(characters[$0..<min($0 + 4, characters.count)]) }.joined(separator: " ")
    }

    public static func request(confirmation: String) -> Bool {
        guard valid(confirmation) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script, formatted(confirmation)]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return false }
        guard finished.wait(timeout: .now() + 60) == .success else {
            process.terminate()
            return false
        }
        guard process.terminationStatus == 0 else { return false }
        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        return text?.trimmingCharacters(in: .whitespacesAndNewlines) == "approved"
    }
}
