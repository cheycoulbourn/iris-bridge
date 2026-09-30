public enum BridgeVersion {
    public static let current = "0.3.1"
    public static let protocolVersion = 2
    /// What this helper can do, by name (contract §3). The app enables a feature when its name is listed, and
    /// compares versions only for helpers that send no list (0.2.4 and older). The first four name the app's
    /// old version gates: chat 0.1.0, inbox 0.2.0, modelSelection 0.2.3, plannerAccess 0.2.4. `v3` is the
    /// WebSocket stream, sessions, the new Iris tools and approvals (0.3.0). `effort` is `thread.send.effort`:
    /// the app shows the reasoning-effort choice only when it is listed (`StreamIdentifiers.efforts`).
    /// `postReferences` adds id-only, replayable post.referenced events; older apps ignore this type.
    public static let capabilities = ["chat", "inbox", "modelSelection", "plannerAccess", "causes", "health", "authStatus", "v3", "effort", "postReferences"]
}
