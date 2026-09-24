import Foundation

public final class LiveGenerator: Generator {
    public let runner = ForegroundProcessRunner()
    public let providers: ProviderService
    public init() { providers = ProviderService(runner: runner) }
    public func generate(_ request: MessageRequest) throws -> [String: Any] {
        defer { if let id = request.id { runner.clearCanceled(id) } }
        return try providers.generate(request)
    }
    /// How long `/status` waits for a sign-in check, per provider. The app gives the whole poll two seconds; a check
    /// still running after this is answered with its last real result (or "couldn't check") and finishes behind it.
    public static let statusWait: TimeInterval = 0.75
    public func status(_ provider: String) -> ProviderStatus { providers.status(provider, wait: Self.statusWait) }
    /// Starts both sign-in checks without waiting, as the helper starts.
    public func startSignInChecks() { providers.startSignInChecks() }
    public func health(_ provider: String) -> ProviderHealth { providers.health(provider) }
    public func health(_ provider: String, signIn: ProviderStatus) -> ProviderHealth { providers.health(provider, signIn: signIn) }
    public func models(_ provider: String) -> ProviderModelCatalog { providers.models(provider) }
    public func cancel(_ id: String) { runner.markCanceled(id) }
}
