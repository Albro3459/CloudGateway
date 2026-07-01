import CloudGatewayKit
import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = CloudGatewayViewModel()

    var body: some View {
        NavigationStack {
            Form {
                if viewModel.isSignedIn {
                    accountSection
                    tunnelSection
                    configsSection
                } else {
                    signInSection
                    tunnelSection
                }

                if let staleText = viewModel.staleText {
                    Section("Remote State") {
                        Text(staleText)
                            .foregroundStyle(.orange)
                    }
                }

                if let errorText = viewModel.errorText {
                    Section("Error") {
                        Text(errorText)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("CloudGateway")
        }
    }

    private var signInSection: some View {
        Section("Sign In") {
            TextField("Email", text: $viewModel.email)
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
                .autocorrectionDisabled()

            SecureField("Password", text: $viewModel.password)

            Button("Sign In") {
                Task {
                    await viewModel.signIn()
                }
            }
            .disabled(viewModel.isWorking)
        }
    }

    private var accountSection: some View {
        Section("Account") {
            if let signedInEmail = viewModel.signedInEmail {
                LabeledContent("Email", value: signedInEmail)
            }
            if let role = viewModel.role {
                LabeledContent("Role", value: role)
            }
            if let lastRefreshText = viewModel.lastRefreshText {
                LabeledContent("Configs", value: lastRefreshText)
            }

            HStack {
                Button("Refresh") {
                    Task {
                        await viewModel.refresh()
                    }
                }
                .disabled(viewModel.isWorking)

                Button("Sign Out") {
                    Task {
                        await viewModel.signOut()
                    }
                }
                .disabled(viewModel.isWorking)
            }
            .buttonStyle(.borderless)
        }
    }

    private var tunnelSection: some View {
        Section("Tunnel") {
            Text(viewModel.statusText)
                .foregroundStyle(statusColor)

            if let cachedSnapshot = viewModel.cachedSnapshot {
                LabeledContent("Installed", value: cachedSnapshot.clientDisplayName)
                LabeledContent("Region", value: cachedSnapshot.regionDisplayName)
            }

            HStack {
                Button("Start") {
                    Task {
                        await viewModel.startTunnel()
                    }
                }
                .disabled(viewModel.startDisabled)

                Button("Stop") {
                    Task {
                        await viewModel.stopTunnel()
                    }
                }
                .disabled(viewModel.isWorking || viewModel.tunnelStatus == nil || viewModel.tunnelStatus == .disconnected || viewModel.tunnelStatus == .disconnecting)
            }
            .buttonStyle(.borderless)

            Button("Remove VPN", role: .destructive) {
                Task {
                    await viewModel.removeTunnel()
                }
            }
            .disabled(viewModel.isWorking || viewModel.tunnelStatus == nil)
        }
    }

    private var configsSection: some View {
        Section("Available Configs") {
            if viewModel.configOptions.isEmpty {
                Text("No active CloudGateway client config found.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.configOptions) { option in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.client.displayName)
                                    .font(.headline)
                                Text(option.regionDisplayName)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let installStateLabel = viewModel.installStateLabel(for: option) {
                                Text(installStateLabel)
                                    .font(.caption)
                                    .foregroundStyle(installStateLabel == "Installed" ? .green : .orange)
                            }
                        }

                        Button(viewModel.installButtonTitle(for: option)) {
                            Task {
                                await viewModel.install(option)
                            }
                        }
                        .disabled(viewModel.isWorking)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var statusColor: Color {
        switch viewModel.tunnelStatus {
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

#Preview {
    ContentView()
}
