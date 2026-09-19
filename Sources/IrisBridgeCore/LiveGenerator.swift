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
    public func status(_ provider: String) -> ProviderStatus { providers.status(provider) }
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
}
