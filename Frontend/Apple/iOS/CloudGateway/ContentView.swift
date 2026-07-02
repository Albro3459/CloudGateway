import AuthenticationServices
import CloudGatewayKit
import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = CloudGatewayViewModel()
    @State private var clientPendingDelete: CloudGatewayClientOption?
    @State private var isShowingLogin = false
    @State private var isShowingAbout = false
    @State private var isConfirmingReset = false
    @State private var appleRawNonce = ""
    @Environment(\.cloudGatewayTheme) private var theme

    var body: some View {
        ZStack {
            theme.page.ignoresSafeArea()

            switch viewModel.appMode {
            case .loading:
                loadingView
            case .guest:
                if isShowingLogin {
                    loginView
                } else {
                    guestDashboard
                }
            case .signedIn:
                signedInDashboard
            }

            if viewModel.isWorking {
                workingOverlay
            }
        }
        .foregroundStyle(theme.content)
        .onChange(of: viewModel.appMode) { _, mode in
            if mode == .signedIn {
                isShowingLogin = false
            }
        }
        .sheet(isPresented: $isShowingAbout) {
            AboutView(version: versionText) {
                isShowingAbout = false
            }
        }
        .alert("Send password reset email?", isPresented: $isConfirmingReset) {
            Button("Send") {
                Task {
                    await viewModel.resetPassword()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("We'll email a password reset link to the address entered above.")
        }
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

    private var loadingView: some View {
        VStack(spacing: 14) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(theme.content)
            Text("CloudGateway")
                .font(.headline)
                .foregroundStyle(theme.contentSecondary)
        }
    }

    private var signedInDashboard: some View {
        VStack(spacing: 0) {
            signedInNav

            ScrollView {
                VStack(spacing: 16) {
                    messages

                    if viewModel.isAdmin {
                        adminPanel
                    }

                    regionsPanel
                    createPanel
                    clientsPanel
                    tunnelPanel
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
            }
            .refreshable {
                await viewModel.refresh()
            }
        }
    }

    private var guestDashboard: some View {
        VStack(spacing: 0) {
            guestNav

            ScrollView {
                VStack(spacing: 16) {
                    messages
                    regionsPanel
                    guestCreatePanel
                    guestClientsPanel
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
            }
            .refreshable {
                await viewModel.refresh()
            }
        }
    }

    private var signedInNav: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("CloudGateway")
                    .font(.headline)
                    .foregroundStyle(theme.content)
                if let signedInEmail = viewModel.signedInEmail {
                    Text(signedInEmail)
                        .font(.caption)
                        .foregroundStyle(theme.contentSecondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Button {
                isShowingAbout = true
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(IconNavButtonStyle())
            .accessibilityLabel("About")

            Button {
                Task {
                    await viewModel.refresh()
                }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(IconNavButtonStyle())
            .disabled(viewModel.isWorking)
            .accessibilityLabel("Refresh")

            Button("Logout") {
                Task {
                    await viewModel.signOut()
                }
            }
            .buttonStyle(NavTextButtonStyle())
            .disabled(viewModel.isWorking)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(theme.nav)
    }

    private var guestNav: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("CloudGateway")
                    .font(.headline)
                    .foregroundStyle(theme.content)
                Text("Guest")
                    .font(.caption)
                    .foregroundStyle(theme.contentSecondary)
            }

            Spacer()

            Button {
                isShowingAbout = true
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(IconNavButtonStyle())
            .accessibilityLabel("About")

            Button {
                Task {
                    await viewModel.refresh()
                }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(IconNavButtonStyle())
            .disabled(viewModel.isWorking)
            .accessibilityLabel("Refresh")

            Button("Sign in") {
                isShowingLogin = true
            }
            .buttonStyle(NavTextButtonStyle())
            .disabled(viewModel.isWorking)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(theme.nav)
    }

    private var loginView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    isShowingLogin = false
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(IconNavButtonStyle())
                .accessibilityLabel("Back")

                Text("CloudGateway")
                    .font(.headline)
                    .foregroundStyle(theme.content)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(theme.nav)

            ScrollView {
                VStack(spacing: 16) {
                    messages

                    ThemedPanel {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Login")
                                .font(.title2.bold())
                                .foregroundStyle(theme.content)

                            ThemedTextField(
                                title: "Email",
                                placeholder: "Enter your email",
                                text: $viewModel.email,
                                keyboardType: .emailAddress
                            )

                            ThemedSecureField(
                                title: "Password",
                                placeholder: "Enter your password",
                                text: $viewModel.password
                            )

                            Button("Login") {
                                Task {
                                    await viewModel.signIn()
                                }
                            }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(viewModel.isWorking)

                            Button {
                                isConfirmingReset = true
                            } label: {
                                Text("Reset password")
                                    .font(.footnote.weight(.medium))
                                    .foregroundStyle(theme.accent)
                            }
                            .buttonStyle(.plain)
                            .disabled(viewModel.isWorking)

                            VStack(spacing: 10) {
                                DividerLine(text: "or")

                                SignInWithAppleButton(.signIn) { request in
                                    let nonce = AppleSignInNonce.randomNonceString()
                                    appleRawNonce = nonce
                                    request.requestedScopes = [.fullName, .email]
                                    request.nonce = AppleSignInNonce.sha256(nonce)
                                } onCompletion: { result in
                                    handleAppleCompletion(result)
                                }
                                .signInWithAppleButtonStyle(.whiteOutline)
                                .frame(height: 44)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .disabled(viewModel.isWorking)

                                Button {
                                    Task {
                                        await viewModel.signInWithGoogle()
                                    }
                                } label: {
                                    Label("Continue with Google", systemImage: "g.circle")
                                }
                                .buttonStyle(SecondaryButtonStyle())
                                .disabled(viewModel.isWorking)

                                Button {
                                    Task {
                                        await viewModel.continueAsGuest()
                                        isShowingLogin = false
                                    }
                                } label: {
                                    Label("Continue as Guest", systemImage: "eye")
                                }
                                .buttonStyle(SecondaryButtonStyle())
                                .disabled(viewModel.isWorking)
                            }

                            Link(destination: requestAccessURL) {
                                Label("Request access", systemImage: "envelope")
                            }
                            .buttonStyle(SecondaryButtonStyle())
                        }
                    }

                    Text(versionText)
                        .font(.caption)
                        .foregroundStyle(theme.contentFaint)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
            }
        }
    }

    @ViewBuilder
    private var messages: some View {
        if let errorText = viewModel.errorText {
            MessageBanner(
                text: errorText,
                style: .error,
                onDismiss: viewModel.dismissMessages
            )
        } else if let successText = viewModel.successText {
            MessageBanner(
                text: successText,
                style: .success,
                onDismiss: viewModel.dismissMessages
            )
        }

        if let staleText = viewModel.staleText {
            MessageBanner(
                text: staleText,
                style: .warning,
                onDismiss: nil
            )
        }
    }

    private var adminPanel: some View {
        ThemedPanel {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(
                    title: "Admin",
                    subtitle: "Manage regions and user access."
                )

                VStack(alignment: .leading, spacing: 10) {
                    Text("Sync the selected region's live peers with Firebase.")
                        .font(.subheadline)
                        .foregroundStyle(theme.contentMuted)

                    Button {
                        Task {
                            await viewModel.syncSelectedRegion()
                        }
                    } label: {
                        Label("Sync Selected Region", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(!viewModel.canSyncSelectedRegion)

                    if let lastSyncText = viewModel.lastSyncText {
                        Text(lastSyncText)
                            .font(.caption)
                            .foregroundStyle(theme.contentMuted)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    ThemedTextField(
                        title: "Grant User Access",
                        placeholder: "Email",
                        text: $viewModel.newAccessEmail,
                        keyboardType: .emailAddress
                    )

                    Button {
                        Task {
                            await viewModel.grantAccess()
                        }
                    } label: {
                        Label("Grant Access", systemImage: "person.badge.plus")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(!viewModel.canGrantAccess)
                }
            }
        }
    }

    private var regionsPanel: some View {
        ThemedPanel {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(
                    title: "Regions",
                    subtitle: "Choose where new VPN clients are created."
                )

                if viewModel.regions.isEmpty {
                    Text("No enabled regions are available.")
                        .font(.subheadline)
                        .foregroundStyle(theme.contentMuted)
                } else {
                    FlowLayout(spacing: 10) {
                        ForEach(viewModel.regions, id: \.regionId) { region in
                            RegionButton(
                                region: region,
                                isSelected: region.regionId == viewModel.selectedRegionId,
                                showsCapacity: viewModel.isSignedIn
                            ) {
                                viewModel.selectedRegionId = region.regionId
                            }
                        }
                    }

                    if viewModel.isSignedIn, let selectedRegion = viewModel.selectedRegion {
                        RegionCapacityNote(region: selectedRegion)
                    }
                }
            }
        }
    }

    private var createPanel: some View {
        ThemedPanel {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(
                    title: "Create Client",
                    subtitle: "Create a WireGuard config in the selected region."
                )

                ThemedTextField(
                    title: "Client display name",
                    placeholder: "Optional",
                    text: $viewModel.newClientName,
                    keyboardType: .default
                )

                Button {
                    Task {
                        await viewModel.createClient()
                    }
                } label: {
                    Label("Create Client", systemImage: "plus")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(viewModel.createDisabled)
            }
        }
    }

    private var guestCreatePanel: some View {
        ThemedPanel {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(
                    title: "Create Client",
                    subtitle: "Sign in before creating a WireGuard config."
                )

                HStack(spacing: 10) {
                    Button("Sign in") {
                        isShowingLogin = true
                    }
                    .buttonStyle(PrimaryButtonStyle())

                    Link(destination: requestAccessURL) {
                        Label("Request Access", systemImage: "envelope")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
    }

    private var guestClientsPanel: some View {
        ThemedPanel {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(
                    title: "VPN Clients",
                    subtitle: "Sign in to see your VPN clients on this device."
                )

                EmptyState(
                    title: "Clients are hidden while signed out",
                    message: "Guest mode only shows available regions."
                )

                Button("Sign in") {
                    isShowingLogin = true
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    private var clientsPanel: some View {
        ThemedPanel {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(
                    title: "VPN Clients",
                    subtitle: viewModel.isAdmin ? "Showing clients visible to your account." : "Install, update, or remove your clients."
                )

                if viewModel.filteredClientOptions.isEmpty {
                    EmptyState(
                        title: "No clients in this region",
                        message: "Create a client to install a VPN profile on this device."
                    )
                } else {
                    VStack(spacing: 10) {
                        ForEach(viewModel.filteredClientOptions) { option in
                            ClientRow(
                                option: option,
                                isSelected: viewModel.selectedClientId == option.client.clientId,
                                installState: viewModel.installStateLabel(for: option),
                                installTitle: viewModel.installButtonTitle(for: option),
                                installDisabled: viewModel.selectedClientId == option.client.clientId ? viewModel.installDisabled : !option.client.hasUsableConfig,
                                deleteDisabled: viewModel.deleteDisabled(for: option),
                                onSelect: {
                                    viewModel.selectedClientId = option.client.clientId
                                },
                                onInstall: {
                                    viewModel.selectedClientId = option.client.clientId
                                    Task {
                                        await viewModel.install(option)
                                    }
                                },
                                onDelete: {
                                    viewModel.selectedClientId = option.client.clientId
                                    clientPendingDelete = option
                                }
                            )
                        }
                    }
                }
            }
        }
    }

    private var tunnelPanel: some View {
        ThemedPanel {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(
                    title: "Installed VPN",
                    subtitle: "Manage the local VPN profile on this device."
                )

                HStack(spacing: 10) {
                    TunnelStatusBadge(status: viewModel.visibleTunnelStatus)
                    Text(viewModel.statusText)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(theme.contentSecondary)
                    Spacer()
                }

                if let cachedSnapshot = viewModel.visibleCachedSnapshot {
                    VStack(alignment: .leading, spacing: 6) {
                        DetailLine(label: "Installed", value: cachedSnapshot.clientDisplayName)
                        DetailLine(label: "Region", value: cachedSnapshot.regionDisplayName)
                    }
                } else {
                    EmptyState(
                        title: "No VPN profile installed",
                        message: "Install an active client to create the local VPN profile."
                    )
                }

                HStack(spacing: 10) {
                    Button("Start") {
                        Task {
                            await viewModel.startTunnel()
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(viewModel.startDisabled)

                    Button("Stop") {
                        Task {
                            await viewModel.stopTunnel()
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(viewModel.stopDisabled)
                }

                Button(role: .destructive) {
                    Task {
                        await viewModel.removeTunnel()
                    }
                } label: {
                    Label("Remove VPN", systemImage: "trash")
                }
                .buttonStyle(DangerButtonStyle())
                .disabled(viewModel.removeTunnelDisabled)
            }
        }
    }

    private var workingOverlay: some View {
        ZStack {
            theme.scrim.opacity(0.48).ignoresSafeArea()
            ProgressView()
                .progressViewStyle(.circular)
                .tint(theme.content)
                .scaleEffect(1.3)
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

    private var versionText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return "v\(version ?? "1.0")"
    }

    private var requestAccessURL: URL {
        URL(string: "mailto:Brodsky.Alex22@gmail.com?subject=CloudGateway%20Access%20Request")!
    }

    private func handleAppleCompletion(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard
                let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                let tokenData = credential.identityToken,
                let idToken = String(data: tokenData, encoding: .utf8)
            else {
                Task {
                    await viewModel.reportAppleSignInFailure()
                }
                return
            }
            Task {
                await viewModel.completeAppleSignIn(idToken: idToken, rawNonce: appleRawNonce)
            }
        case .failure(let error):
            if let authError = error as? ASAuthorizationError, authError.code == .canceled {
                return
            }
            Task {
                await viewModel.reportAppleSignInFailure()
            }
        }
    }
}

private struct ThemedPanel<Content: View>: View {
    @Environment(\.cloudGatewayTheme) private var theme
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(theme.edgeFaint, lineWidth: 1)
            }
    }
}

private struct SectionHeader: View {
    @Environment(\.cloudGatewayTheme) private var theme
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title3.bold())
                .foregroundStyle(theme.content)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(theme.contentMuted)
        }
    }
}

private struct AboutView: View {
    @Environment(\.cloudGatewayTheme) private var theme
    let version: String
    let onClose: () -> Void

    var body: some View {
        ZStack {
            theme.page.ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text("About")
                        .font(.headline)
                        .foregroundStyle(theme.content)
                    Spacer()
                    Button("Done", action: onClose)
                        .buttonStyle(NavTextButtonStyle())
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(theme.nav)

                ScrollView {
                    VStack(spacing: 16) {
                        ThemedPanel {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("What is CloudGateway?")
                                    .font(.title2.bold())
                                    .foregroundStyle(theme.content)

                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Created by Alex Brodsky")
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(theme.contentSecondary)
                                    HStack(spacing: 14) {
                                        Link("GitHub", destination: URL(string: "https://github.com/Albro3459/CloudGateway/")!)
                                        Link("LinkedIn", destination: URL(string: "https://www.linkedin.com/in/brodsky-alex22/")!)
                                        Link("Email", destination: URL(string: "mailto:Brodsky.Alex22@gmail.com")!)
                                    }
                                    .font(.caption.weight(.semibold))
                                    .tint(theme.accent)
                                }

                                Text("Create secure WireGuard VPN clients on shared regional CloudGateway servers, pre-configured with IPv4, IPv6, and DNS.")
                                    .foregroundStyle(theme.contentSecondary)
                                Text("Each region runs a dedicated FastAPI control plane behind Cloudflare-protected Caddy, with Firebase storing user and client state.")
                                    .foregroundStyle(theme.contentSecondary)
                                Text("Create a config in the selected region and install it on this device in just a few taps.")
                                    .foregroundStyle(theme.contentSecondary)
                                Text("Secure, simple, and instant. Your personal VPN clients, managed on demand.")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(theme.content)
                            }
                        }

                        Text(version)
                            .font(.caption)
                            .foregroundStyle(theme.contentFaint)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
                }
            }
        }
        .foregroundStyle(theme.content)
    }
}

private struct ThemedTextField: View {
    @Environment(\.cloudGatewayTheme) private var theme
    let title: String
    let placeholder: String
    @Binding var text: String
    let keyboardType: UIKeyboardType

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(theme.contentSecondary)
            TextField(placeholder, text: $text)
                .textInputAutocapitalization(keyboardType == .emailAddress ? .never : .words)
                .keyboardType(keyboardType)
                .autocorrectionDisabled(keyboardType == .emailAddress)
                .padding(12)
                .background(theme.inset)
                .foregroundStyle(theme.content)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(theme.edge, lineWidth: 1)
                }
        }
    }
}

private struct ThemedSecureField: View {
    @Environment(\.cloudGatewayTheme) private var theme
    let title: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(theme.contentSecondary)
            SecureField(placeholder, text: $text)
                .padding(12)
                .background(theme.inset)
                .foregroundStyle(theme.content)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(theme.edge, lineWidth: 1)
                }
        }
    }
}

private struct RegionButton: View {
    @Environment(\.cloudGatewayTheme) private var theme
    let region: CloudGatewayRegion
    let isSelected: Bool
    let showsCapacity: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(region.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isSelected ? theme.accent : theme.contentSecondary)
                if showsCapacity {
                    Text(region.capacity?.displayText ?? "Capacity unavailable")
                        .font(.caption)
                        .foregroundStyle(capacityColor)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(isSelected ? theme.primarySoft : theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? theme.primary : theme.edgeSubtle, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private var capacityColor: Color {
        guard let capacity = region.capacity, capacity.isKnown, !capacity.isAtCapacity else {
            return theme.dangerContent
        }
        return theme.contentMuted
    }
}

private struct DividerLine: View {
    @Environment(\.cloudGatewayTheme) private var theme
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(theme.edgeSubtle)
                .frame(height: 1)
            Text(text)
                .font(.caption)
                .foregroundStyle(theme.contentFaint)
            Rectangle()
                .fill(theme.edgeSubtle)
                .frame(height: 1)
        }
    }
}

private struct RegionCapacityNote: View {
    @Environment(\.cloudGatewayTheme) private var theme
    let region: CloudGatewayRegion

    var body: some View {
        if let capacity = region.capacity, capacity.isKnown {
            if capacity.isAtCapacity {
                Text("\(region.displayName) is currently full. Choose another region before creating a client.")
                    .font(.subheadline)
                    .foregroundStyle(theme.dangerContent)
            }
        } else {
            Text("Capacity for \(region.displayName) is unavailable. Try again in a moment.")
                .font(.subheadline)
                .foregroundStyle(theme.dangerContent)
        }
    }
}

private struct ClientRow: View {
    @Environment(\.cloudGatewayTheme) private var theme
    let option: CloudGatewayClientOption
    let isSelected: Bool
    let installState: String?
    let installTitle: String
    let installDisabled: Bool
    let deleteDisabled: Bool
    let onSelect: () -> Void
    let onInstall: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: onSelect) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(option.client.displayName)
                            .font(.headline)
                            .foregroundStyle(theme.content)
                        Text(option.regionDisplayName)
                            .font(.subheadline)
                            .foregroundStyle(theme.contentMuted)
                        Text(option.client.clientId)
                            .font(.caption.monospaced())
                            .foregroundStyle(theme.contentFaint)
                            .lineLimit(1)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 6) {
                        StatusBadge(status: option.client.status)
                        if let installState {
                            Text(installState)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(theme.accentStrong)
                        }
                    }
                }
            }
            .buttonStyle(.plain)

            HStack(spacing: 10) {
                Button(installTitle, action: onInstall)
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(installDisabled)

                Button(role: .destructive, action: onDelete) {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(DangerButtonStyle())
                .disabled(deleteDisabled)
            }
        }
        .padding(12)
        .background(isSelected ? theme.inset : theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isSelected ? theme.primarySoftEdge : theme.edgeFaint, lineWidth: 1)
        }
    }
}

private struct StatusBadge: View {
    @Environment(\.cloudGatewayTheme) private var theme
    let status: CloudGatewayClientStatus

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(backgroundColor)
            .foregroundStyle(foregroundColor)
            .clipShape(Capsule())
            .overlay {
                Capsule().stroke(borderColor, lineWidth: 1)
            }
    }

    private var title: String {
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

    private var backgroundColor: Color {
        switch status {
        case .active:
            theme.successSoft
        case .creating:
            theme.warningSoft
        case .failed:
            theme.dangerSoft
        case .removed:
            theme.neutralStrong
        }
    }

    private var foregroundColor: Color {
        switch status {
        case .active:
            theme.successStrong
        case .creating:
            theme.warningStrong
        case .failed:
            theme.dangerStrong
        case .removed:
            theme.content
        }
    }

    private var borderColor: Color {
        switch status {
        case .active:
            theme.successSoftEdge
        case .creating:
            theme.warningSoftEdge
        case .failed:
            theme.dangerSoftEdge
        case .removed:
            theme.neutralStrong
        }
    }
}

private struct TunnelStatusBadge: View {
    @Environment(\.cloudGatewayTheme) private var theme
    let status: GatewayTunnelStatus?

    var body: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 10, height: 10)
            .accessibilityHidden(true)
    }

    private var statusColor: Color {
        switch status {
        case .connected:
            theme.successStrong
        case .connecting, .reasserting, .disconnecting:
            theme.warningStrong
        case .invalid:
            theme.dangerContent
        case .disconnected, nil:
            theme.contentFaint
        }
    }
}

private struct DetailLine: View {
    @Environment(\.cloudGatewayTheme) private var theme
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
                .foregroundStyle(theme.contentFaint)
            Spacer()
            Text(value)
                .font(.subheadline)
                .foregroundStyle(theme.contentSecondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct EmptyState: View {
    @Environment(\.cloudGatewayTheme) private var theme
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.contentSecondary)
            Text(message)
                .font(.caption)
                .foregroundStyle(theme.contentMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(theme.inset)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private enum MessageBannerStyle {
    case error
    case success
    case warning
}

private struct MessageBanner: View {
    @Environment(\.cloudGatewayTheme) private var theme
    let text: String
    let style: MessageBannerStyle
    let onDismiss: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(foregroundColor)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(foregroundColor)
                .accessibilityLabel("Dismiss message")
            }
        }
        .padding(12)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        }
    }

    private var backgroundColor: Color {
        switch style {
        case .error:
            theme.danger
        case .success:
            theme.success
        case .warning:
            theme.warningSoft
        }
    }

    private var foregroundColor: Color {
        switch style {
        case .error, .success:
            theme.content
        case .warning:
            theme.warningStrong
        }
    }

    private var borderColor: Color {
        switch style {
        case .error:
            theme.dangerSoftEdge
        case .success:
            theme.successSoftEdge
        case .warning:
            theme.warningSoftEdge
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 0
        let rows = rows(in: maxWidth, subviews: subviews)
        let height = rows.reduce(CGFloat.zero) { result, row in
            result + row.height
        } + CGFloat(max(rows.count - 1, 0)) * spacing
        return CGSize(width: maxWidth, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = rows(in: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y),
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func rows(in maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        guard maxWidth > 0 else {
            return []
        }

        var rows = [Row]()
        var current = Row()

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let nextWidth = current.width == 0 ? size.width : current.width + spacing + size.width
            if nextWidth > maxWidth && !current.items.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.items.append(RowItem(index: index, size: size))
            current.width = current.width == 0 ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
        }

        if !current.items.isEmpty {
            rows.append(current)
        }

        return rows
    }

    private struct Row {
        var items = [RowItem]()
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private struct RowItem {
        let index: Int
        let size: CGSize
    }
}

private struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.cloudGatewayTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(isEnabled ? (configuration.isPressed ? theme.primaryHover : theme.primary) : theme.disabled)
            .foregroundStyle(isEnabled ? theme.content : theme.contentDisabled)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.cloudGatewayTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(isEnabled ? (configuration.isPressed ? theme.insetStrongHover : theme.insetStrong) : theme.disabled)
            .foregroundStyle(isEnabled ? theme.contentSecondary : theme.contentDisabled)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct DangerButtonStyle: ButtonStyle {
    @Environment(\.cloudGatewayTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(isEnabled ? (configuration.isPressed ? theme.dangerButtonHover : theme.dangerButton) : theme.disabled)
            .foregroundStyle(isEnabled ? theme.content : theme.contentDisabled)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct NavTextButtonStyle: ButtonStyle {
    @Environment(\.cloudGatewayTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(configuration.isPressed ? theme.navButtonHover : theme.navButton)
            .foregroundStyle(isEnabled ? theme.accent : theme.contentDisabled)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct IconNavButtonStyle: ButtonStyle {
    @Environment(\.cloudGatewayTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .frame(width: 38, height: 38)
            .background(configuration.isPressed ? theme.navButtonHover : theme.navButton)
            .foregroundStyle(isEnabled ? theme.accent : theme.contentDisabled)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

#Preview {
    ContentView()
        .environment(\.cloudGatewayTheme, CloudGatewayTheme())
        .preferredColorScheme(.dark)
}
