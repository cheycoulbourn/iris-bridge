import Foundation
import SystemConfiguration

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
