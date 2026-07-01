import CloudGatewayKit
import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = CloudGatewayViewModel()
    @State private var clientPendingDelete: CloudGatewayClientOption?

    var body: some View {
        NavigationStack {
            Form {
                if viewModel.isSignedIn {
                    accountSection
                    regionsSection
                    createSection
                    configsSection
                    selectedConfigSection
                    tunnelSection
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
            .alert("Delete Config?", isPresented: deleteConfirmationPresented) {
                Button("Delete", role: .destructive) {
                    Task {
                        await viewModel.deleteSelectedClient()
                    }
                }
                Button("Cancel", role: .cancel) {
                    clientPendingDelete = nil
                }
            } message: {
                if let clientPendingDelete {
                    Text("Delete \(clientPendingDelete.client.displayName) in \(clientPendingDelete.regionDisplayName)? This removes the regional WireGuard peer and the local VPN profile if this config is installed.")
                }
            }
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
            if let lastSyncText = viewModel.lastSyncText {
                LabeledContent("Last Sync", value: lastSyncText)
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

    private var regionsSection: some View {
        Section("Regions") {
            if viewModel.regions.isEmpty {
                Text("No enabled regions are available.")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Region", selection: $viewModel.selectedRegionId) {
                    ForEach(viewModel.regions, id: \.regionId) { region in
                        Text(region.displayName).tag(Optional(region.regionId))
                    }
                }

                if let region = viewModel.selectedRegion {
                    LabeledContent("Selected", value: region.regionId)
                    if let capacity = region.capacity {
                        LabeledContent("Capacity", value: capacity.displayText)
                            .foregroundStyle(capacity.isAtCapacity ? .red : .primary)
                    } else {
                        LabeledContent("Capacity", value: "Loading")
                    }
                    if region.capacity?.isAtCapacity == true {
                        Text("This region is currently full. Choose another region before creating a config.")
                            .foregroundStyle(.red)
                    }
                    if viewModel.role == "admin" {
                        Button("Sync Selected Region") {
                            Task {
                                await viewModel.syncSelectedRegion()
                            }
                        }
                        .disabled(!viewModel.canSyncSelectedRegion)
                    }
                }
            }
        }
    }

    private var createSection: some View {
        Section("Create Config") {
            TextField("Name", text: $viewModel.newClientName)
                .textInputAutocapitalization(.words)

            Button("Create In Selected Region") {
                Task {
                    await viewModel.createClient()
                }
            }
            .disabled(viewModel.createDisabled)
        }
    }

    private var configsSection: some View {
        Section("Owned Configs") {
            if viewModel.filteredClientOptions.isEmpty {
                Text("No configs found in this region.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.filteredClientOptions) { option in
                    Button {
                        viewModel.selectedClientId = option.client.clientId
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.client.displayName)
                                    .font(.headline)
                                Text(option.regionDisplayName)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Text(statusText(for: option.client.status))
                                    .font(.caption)
                                    .foregroundStyle(statusColor(for: option.client.status))
                            }
                            Spacer()
                            if viewModel.selectedClientId == option.client.clientId {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var selectedConfigSection: some View {
        Section("Selected Config") {
            if let option = viewModel.selectedClientOption {
                LabeledContent("Name", value: option.client.displayName)
                LabeledContent("Region", value: option.regionDisplayName)
                LabeledContent("Status", value: statusText(for: option.client.status))

                if let installStateLabel = viewModel.installStateLabel(for: option) {
                    LabeledContent("Local", value: installStateLabel)
                }

                Button(viewModel.installButtonTitle(for: option)) {
                    Task {
                        await viewModel.installSelectedClient()
                    }
                }
                .disabled(viewModel.installDisabled)

                Button("Delete Config", role: .destructive) {
                    clientPendingDelete = option
                }
                .disabled(viewModel.deleteDisabled)
            } else {
                Text("Choose a config to view details and actions.")
                    .foregroundStyle(.secondary)
            }
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

    private var deleteConfirmationPresented: Binding<Bool> {
        Binding(
            get: { clientPendingDelete != nil },
            set: { isPresented in
                if !isPresented {
                    clientPendingDelete = nil
                }
            }
        )
    }

    private func statusText(for status: CloudGatewayClientStatus) -> String {
        switch status {
        case .creating:
            "Creating"
        case .active:
            "Active"
        case .failed:
            "Failed"
        case .removed:
            "Removed"
        }
    }

    private func statusColor(for status: CloudGatewayClientStatus) -> Color {
        switch status {
        case .active:
            .green
        case .creating:
            .orange
        case .failed:
            .red
        case .removed:
            .secondary
        }
    }
}

#Preview {
    ContentView()
}
