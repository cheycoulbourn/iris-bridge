import Foundation
import SystemConfiguration

public final class LiveGenerator: Generator {
    public let runner = ForegroundProcessRunner()
    public let providers: ProviderService
    public init() { providers = ProviderService(runner: runner) }
    public func generate(_ request: MessageRequest) throws -> [String: Any] {
        defer { if let id = request.id { runner.clearCanceled(id) } }
        return try providers.generate(request)
    }
    /// How long `/status` waits for the CLIs, in all: both sign-in checks and both version reads share it. The app
    /// gives the whole poll two seconds; anything still running after this is answered with its last real result
    /// (or "couldn't check", or no version yet) and finishes behind it.
    public static let statusWait: TimeInterval = 0.75
    public func status(_ provider: String) -> ProviderStatus { providers.status(provider, wait: Self.statusWait) }
    public func statuses(_ names: [String]) -> [String: ProviderStatus] { providers.statuses(names, wait: Self.statusWait) }
    /// Starts both sign-in checks and version reads without waiting, as the helper starts.
    public func startSignInChecks() { providers.startSignInChecks() }
    public func health(_ provider: String) -> ProviderHealth { providers.health(provider) }
    /// `/status`'s health: `statuses` already spent the poll's wait, so the version is read without waiting again.
    public func health(_ provider: String, signIn: ProviderStatus) -> ProviderHealth { providers.health(provider, signIn: signIn, versionWait: 0) }
    public func models(_ provider: String) -> ProviderModelCatalog { providers.models(provider) }
    public func cancel(_ id: String) { runner.markCanceled(id) }
}

public enum HostName {
    public static func computerName() -> String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? Host.current().localizedName ?? "Mac"
    }
    public static func localHostName() -> String {
        ((SCDynamicStoreCopyLocalHostName(nil) as String?) ?? Host.current().name?.split(separator: ".").first.map(String.init) ?? "mac") + ".local"
    }

    /// This Mac's IPv4 addresses on interfaces that are up, without loopback or link-local ones. The app
    /// accepts a typed name or IP address (D2); `iris-bridge status` prints these so there is one to type.
    public static func lanAddresses() -> [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var addresses = Set<String>()
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
                  entry.ifa_flags & UInt32(IFF_UP) != 0, entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if !text.hasPrefix("169.254.") { addresses.insert(text) }
        }
        return addresses.sorted()
    }
}
