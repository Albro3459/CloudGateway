import CloudGatewayKit
import SwiftUI

struct ContentView: View {
    @State private var wireGuardConfig = """
    [Interface]
    PrivateKey = <paste-private-key>
    Address = 10.0.0.2/32
    DNS = 9.9.9.9

    [Peer]
    PublicKey = <paste-public-key>
    AllowedIPs = 0.0.0.0/0, ::/0
    Endpoint = wg.us-chicago-1.gocloudlaunch.com:51820
    PersistentKeepalive = 25
    """
    @State private var statusText = "Not installed"
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

                    Button("Install VPN") {
                        Task {
                            await installTunnel()
                        }
                    }
                    .disabled(isWorking)

                    Button("Start") {
                        Task {
                            await startTunnel()
                        }
                    }
                    .disabled(isWorking)

                    Button("Stop") {
                        Task {
                            await stopTunnel()
                        }
                    }
                    .disabled(isWorking)
                }

                Section("WireGuard Config") {
                    TextEditor(text: $wireGuardConfig)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 220)
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
            statusText = "Installed"
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
    private func refreshStatus() async {
        do {
            statusText = try await manager.installedStatus().displayName
        } catch GatewayVPNError.missingInstalledTunnel {
            statusText = "Not installed"
        } catch {
            errorText = error.localizedDescription
        }
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
