import CloudGatewayKit
import SwiftUI
import UIKit

struct ContentView: View {
    private static let templateConfig = """
    [Interface]
    PrivateKey = <paste-private-key>
    Address = 10.0.0.2/32, fd42:42:42::2/128
    DNS = 10.0.0.1, fd42:42:42::1

    [Peer]
    PublicKey = <paste-public-key>
    Endpoint = wg.us-sanjose-1.gocloudlaunch.com:51820
    AllowedIPs = 0.0.0.0/0, ::/0
    PersistentKeepalive = 25
    """

    @State private var wireGuardConfig = templateConfig
    @State private var tunnelStatus: GatewayTunnelStatus?
    @State private var errorText: String?
    @State private var isWorking = false

    private let manager = GatewayVPNManager(
        platform: GatewayPlatformConfiguration(
            appGroupIdentifier: "group.com.gocloudlaunch.gateway",
            appBundleIdentifier: "com.gocloudlaunch.gateway",
            providerBundleIdentifier: "com.gocloudlaunch.gateway.tunnel",
            tunnelDisplayName: "CloudGateway"
        )
    )

    var body: some View {
        NavigationStack {
            Form {
                Section("Tunnel") {
                    Text(statusText)
                        .foregroundStyle(statusColor)

                    Button("Install VPN") {
                        Task {
                            await installTunnel()
                        }
                    }
                    .disabled(isWorking || wireGuardConfig.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("Start") {
                        Task {
                            await startTunnel()
                        }
                    }
                    .disabled(isWorking || tunnelStatus == nil || tunnelStatus == .connected || tunnelStatus == .connecting)

                    Button("Stop") {
                        Task {
                            await stopTunnel()
                        }
                    }
                    .disabled(isWorking || tunnelStatus == nil || tunnelStatus == .disconnected || tunnelStatus == .disconnecting)

                    Button("Remove VPN", role: .destructive) {
                        Task {
                            await removeTunnel()
                        }
                    }
                    .disabled(isWorking || tunnelStatus == nil)
                }

                Section("WireGuard Config") {
                    HStack {
                        Button("Paste") {
                            pasteConfig()
                        }
                        Button("Template") {
                            wireGuardConfig = Self.templateConfig
                            errorText = nil
                        }
                        Button("Clear", role: .destructive) {
                            wireGuardConfig = ""
                            errorText = nil
                        }
                    }

                    TextEditor(text: $wireGuardConfig)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 280)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                if let errorText {
                    Section("Error") {
                        Text(errorText)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("CloudGateway")
            .task {
                await refreshStatus()
            }
        }
    }

    @MainActor
    private func installTunnel() async {
        await run {
            let config = try GatewayWireGuardConfig(wireGuardConfig)
            let tunnel = GatewayTunnelConfiguration(wireGuardConfig: config)
            try await manager.installTunnel(tunnel)
            await refreshStatus()
        }
    }

    @MainActor
    private func startTunnel() async {
        await run {
            try await manager.startTunnel()
            await refreshStatus()
        }
    }

    @MainActor
    private func stopTunnel() async {
        await run {
            try await manager.stopTunnel()
            await refreshStatus()
        }
    }

    @MainActor
    private func removeTunnel() async {
        await run {
            try await manager.removeTunnel()
            tunnelStatus = nil
        }
    }

    @MainActor
    private func refreshStatus() async {
        do {
            tunnelStatus = try await manager.installedStatus()
        } catch GatewayVPNError.missingInstalledTunnel {
            tunnelStatus = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    @MainActor
    private func pasteConfig() {
        guard let pastedConfig = UIPasteboard.general.string,
              !pastedConfig.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorText = "Clipboard does not contain a WireGuard config."
            return
        }

        wireGuardConfig = pastedConfig
        errorText = nil
    }

    @MainActor
    private func run(_ operation: () async throws -> Void) async {
        isWorking = true
        errorText = nil
        defer {
            isWorking = false
        }

        do {
            try await operation()
        } catch {
            errorText = String(describing: error)
        }
    }

    private var statusText: String {
        tunnelStatus?.displayName ?? "Not installed"
    }

    private var statusColor: Color {
        switch tunnelStatus {
        case .connected:
            .green
        case .connecting, .reasserting, .disconnecting:
            .orange
        case .invalid:
            .red
        case .disconnected:
            .secondary
        case nil:
            .secondary
        }
    }
}

private extension GatewayTunnelStatus {
    var displayName: String {
        switch self {
        case .invalid:
            "Invalid"
        case .disconnected:
            "Disconnected"
        case .connecting:
            "Connecting"
        case .connected:
            "Connected"
        case .reasserting:
            "Reasserting"
        case .disconnecting:
            "Disconnecting"
        }
    }
}

#Preview {
    ContentView()
}
