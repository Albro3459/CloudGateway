public enum GatewayInstallEnablePolicy {
    /// iOS keeps a single enabled VPN manager; enabling one disables the others
    /// and drops whichever tunnel is running. Only claim the enabled slot on
    /// install when no *other* tunnel is currently active, so installing a new
    /// config never silently stops the active VPN. `startTunnel` re-enables the
    /// chosen tunnel on demand.
    public static func shouldEnableOnInstall(
        installing identifier: String,
        activeTunnelIdentifiers: Set<String>
    ) -> Bool {
        !activeTunnelIdentifiers.contains { $0 != identifier }
    }
}
