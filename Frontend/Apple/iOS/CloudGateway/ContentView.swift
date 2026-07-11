import AuthenticationServices
import CloudGatewayKit
import SwiftUI
import UIKit
import UserNotifications

struct ContentView: View {
    @StateObject private var viewModel: CloudGatewayViewModel
    @State private var clientPendingDelete: CloudGatewayClientOption?
    @State private var clientShowingDetails: CloudGatewayClientOption?
    @State private var activeTunnelDeleteMessage: String?
    @State private var isShowingLogin = false
    @State private var hasEnteredGuestDashboard = false
    @State private var isShowingAbout = false
    @State private var isShowingAccount = false
    @State private var isShowingAccountLinking = false
    @State private var isShowingDeleteAccount = false
    @State private var isConfirmingReset = false
    @State private var isShowingCreateRestriction = false
    @State private var appleRawNonce = ""
    @State private var linkAccountAppleRawNonce = ""
    @State private var linkAccountAppleReauthRawNonce = ""
    @State private var deleteAccountAppleRawNonce = ""
    @Environment(\.cloudGatewayTheme) private var theme

    @MainActor
    init() {
        _viewModel = StateObject(wrappedValue: CloudGatewayViewModel())
    }

    init(viewModel: CloudGatewayViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        ZStack {
            theme.page.ignoresSafeArea()

            switch viewModel.appMode {
            case .loading:
                loadingView
            case .guest:
                if isShowingLogin || !hasEnteredGuestDashboard {
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

            topMessages
        }
        .foregroundStyle(theme.content)
        .onAppear {
            viewModel.refreshTunnelHealth()
        }
        .task {
            while !Task.isCancelled {
                viewModel.refreshTunnelHealth()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        .onChange(of: viewModel.appMode) { previousMode, mode in
            if mode == .signedIn {
                isShowingLogin = false
                hasEnteredGuestDashboard = false
                isShowingCreateRestriction = false
            } else if previousMode == .signedIn, mode == .guest {
                isShowingLogin = false
                hasEnteredGuestDashboard = false
                isShowingCreateRestriction = false
                isShowingAccount = false
                isShowingAccountLinking = false
                isShowingDeleteAccount = false
            }
        }
        .sheet(isPresented: $isShowingAbout) {
            AboutView(version: versionText) {
                isShowingAbout = false
            }
        }
        .sheet(isPresented: $isShowingAccount) {
            AccountView(
                email: viewModel.signedInEmail,
                isWorking: viewModel.isWorking,
                canLinkAnotherProvider: viewModel.canLinkAnotherProvider,
                onLogout: {
                    isShowingAccount = false
                    Task {
                        await viewModel.signOut()
                    }
                },
                onLinkAnotherProvider: {
                    isShowingAccount = false
                    presentAccountLinking()
                },
                onDelete: {
                    isShowingAccount = false
                    presentDeleteAccount()
                }
            )
        }
        .sheet(isPresented: $isShowingAccountLinking) {
            AccountLinkingView(
                viewModel: viewModel,
                appleRawNonce: $linkAccountAppleRawNonce,
                appleReauthRawNonce: $linkAccountAppleReauthRawNonce,
                onCancel: {
                    viewModel.clearAccountLinkState()
                    isShowingAccountLinking = false
                },
                onAppleLinkCompletion: handleLinkAccountAppleCompletion,
                onAppleReauthCompletion: handleLinkAccountAppleReauthCompletion
            )
        }
        .sheet(isPresented: $isShowingDeleteAccount) {
            DeleteAccountView(
                viewModel: viewModel,
                appleRawNonce: $deleteAccountAppleRawNonce,
                onCancel: {
                    viewModel.deleteAccountPassword = ""
                    isShowingDeleteAccount = false
                },
                onAppleCompletion: handleDeleteAccountAppleCompletion
            )
        }
        .sheet(item: $clientShowingDetails) { option in
            ClientDetailsView(option: option)
        }
        .sheet(isPresented: syncResultPresented) {
            if let result = viewModel.syncResult {
                SyncResultView(result: result)
            }
        }
        .sheet(isPresented: $isShowingCreateRestriction) {
            SignedInRequiredView {
                isShowingCreateRestriction = false
                isShowingLogin = true
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
                guard let option = clientPendingDelete else { return }
                clientPendingDelete = nil
                Task {
                    await viewModel.deleteClient(option)
                }
            }
            Button("Cancel", role: .cancel) {
                clientPendingDelete = nil
            }
        } message: {
            if let clientPendingDelete {
                Text("Delete \(clientPendingDelete.client.displayName) in \(clientPendingDelete.regionDisplayName)? This removes the regional VPN peer and the local VPN profile if this config is installed.")
            }
        }
        .alert("Disconnect First", isPresented: activeTunnelDeletePresented) {
            Button("OK", role: .cancel) {
                activeTunnelDeleteMessage = nil
            }
        } message: {
            if let activeTunnelDeleteMessage {
                Text(activeTunnelDeleteMessage)
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
                    if viewModel.isAdmin {
                        adminPanel
                    }

                    if !viewModel.isUsingOfflineRegionFallback {
                        signedInCreatePanel
                    }
                    regionsPanel
                    clientsPanel
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
            }
            .scrollDismissesKeyboard(.immediately)
            .refreshable {
                await viewModel.pullToRefresh()
            }
        }
    }

    private var guestDashboard: some View {
        VStack(spacing: 0) {
            guestNav

            ScrollView {
                VStack(spacing: 16) {
                    guestCreatePanel
                    regionsPanel
                    guestClientsPanel
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
            }
            .scrollDismissesKeyboard(.immediately)
            .refreshable {
                await viewModel.pullToRefresh()
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

            Button {
                isShowingAccount = true
            } label: {
                Image(systemName: "person.circle")
            }
            .buttonStyle(IconNavButtonStyle())
            .disabled(viewModel.isWorking)
            .accessibilityLabel("Account")
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
                if hasEnteredGuestDashboard {
                    Button {
                        isShowingLogin = false
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(IconNavButtonStyle())
                    .accessibilityLabel("Back")
                }

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

                            Button("Sign in") {
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

                                CustomGoogleSignInButton {
                                    Task {
                                        await viewModel.signInWithGoogle()
                                    }
                                }
                                .disabled(viewModel.isWorking)
                            }

                            VStack(spacing: 10) {
                                Button {
                                    Task {
                                        await viewModel.continueAsGuest()
                                        hasEnteredGuestDashboard = true
                                        isShowingLogin = false
                                    }
                                } label: {
                                    Label("Continue as Guest", systemImage: "eye")
                                }
                                .buttonStyle(SecondaryButtonStyle())
                                .disabled(viewModel.isWorking)
                                
                                Link(destination: requestAccessURL) {
                                    Label("Request Access", systemImage: "envelope")
                                }
                                .buttonStyle(SecondaryButtonStyle())
                            }
                        }
                    }

                    Text(versionText)
                        .font(.caption)
                        .foregroundStyle(theme.contentFaint)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
            }
            .scrollDismissesKeyboard(.immediately)
        }
    }

    @ViewBuilder
    private var topMessages: some View {
        VStack(spacing: 8) {
            if viewModel.shouldShowDeadTunnelWarning {
                MessageBanner(
                    text: CloudGatewayViewModel.deadTunnelMessage,
                    style: .warning,
                    onDismiss: nil,
                    actionTitle: "Disconnect",
                    onAction: {
                        Task {
                            await viewModel.disconnectDeadTunnel()
                        }
                    }
                )
            } else if let errorText = viewModel.errorText {
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

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .allowsHitTesting(
            viewModel.shouldShowDeadTunnelWarning
                || viewModel.errorText != nil
                || viewModel.successText != nil
        )
    }

    private var adminPanel: some View {
        ThemedPanel {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(
                    title: "Admin",
                    subtitle: "Manage regions and user access."
                )

                VStack(alignment: .leading, spacing: 10) {
                    Button {
                        Task {
                            await viewModel.syncSelectedRegion()
                        }
                    } label: {
                        Label("Sync \(viewModel.selectedRegion?.displayName ?? "Region")", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!viewModel.canSyncSelectedRegion)
                }

                VStack(alignment: .leading, spacing: 10) {
                    ThemedTextField(
                        title: "Grant User Access",
                        placeholder: "Email",
                        text: $viewModel.newAccessEmail,
                        keyboardType: .emailAddress
                    )

                    Button {
                        dismissKeyboard()
                        Task {
                            await viewModel.grantAccess()
                        }
                    } label: {
                        Label("Grant Access", systemImage: "person.badge.plus")
                    }
                    .buttonStyle(PrimaryButtonStyle())
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
                    subtitle: viewModel.isUsingOfflineRegionFallback
                        ? "Your installed VPN configs, grouped by region."
                        : "Choose where new VPN clients are created."
                )

                if viewModel.isLoadingRegions {
                    HStack(spacing: 10) {
                        ProgressView()
                            .tint(theme.contentSecondary)
                        Text("Loading regions...")
                            .font(.subheadline)
                            .foregroundStyle(theme.contentMuted)
                    }
                } else if viewModel.regions.isEmpty {
                    Text("No enabled regions are available.")
                        .font(.subheadline)
                        .foregroundStyle(theme.contentMuted)
                } else {
                    FlowLayout(spacing: 10) {
                        ForEach(viewModel.regions, id: \.regionId) { region in
                            RegionButton(
                                region: region,
                                isSelected: region.regionId == viewModel.selectedRegionId,
                                showsCapacity: viewModel.isSignedIn && !viewModel.isUsingOfflineRegionFallback,
                                isLoading: viewModel.isWorking
                            ) {
                                viewModel.selectRegion(region.regionId)
                            }
                        }
                    }

                    if viewModel.isSignedIn,
                       !viewModel.isUsingOfflineRegionFallback,
                       let selectedRegion = viewModel.selectedRegion {
                        RegionCapacityNote(region: selectedRegion, isLoading: viewModel.isWorking)
                    }
                }
            }
        }
    }

    private var signedInCreatePanel: some View {
        createPanel(
            isCreateDisabled: viewModel.createDisabled,
            onCreate: {
                Task {
                    await viewModel.createClient()
                }
            }
        )
    }

    private var guestCreatePanel: some View {
        createPanel(
            isCreateDisabled: guestCreateDisabled,
            onCreate: {
                isShowingCreateRestriction = true
            }
        )
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func createPanel(isCreateDisabled: Bool, onCreate: @escaping () -> Void) -> some View {
        ThemedPanel {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(
                    title: "Create VPN Client",
                    subtitle: "Create a VPN config in \(viewModel.selectedRegion?.displayName ?? "the selected region")."
                )

                ThemedTextField(
                    title: "Display name",
                    placeholder: "ex: John's iPhone",
                    text: $viewModel.newClientName,
                    keyboardType: .default
                )

                Button {
                    dismissKeyboard()
                    onCreate()
                } label: {
                    Label("Create VPN Client", systemImage: "plus")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(isCreateDisabled)
            }
        }
    }

    private var guestClientsPanel: some View {
        ThemedPanel {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(
                    title: "VPN Clients",
                    subtitle: "Manage your VPN clients."
                )

                EmptyState(
                    title: "Clients are hidden while signed out",
                    message: "Guest mode only shows available regions."
                )
            }
        }
    }

    private var clientsPanel: some View {
        ThemedPanel {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(
                    title: "VPN Clients",
                    subtitle: viewModel.isAdmin ? "Manage VPN clients." : "Manage your VPN clients."
                )

                if viewModel.isLoadingClients {
                    HStack(spacing: 10) {
                        ProgressView()
                            .tint(theme.contentSecondary)
                        Text("Loading VPN clients...")
                            .font(.subheadline)
                            .foregroundStyle(theme.contentMuted)
                    }
                } else if viewModel.displayedClientOptions.isEmpty {
                    EmptyState(
                        title: "No clients in this region",
                        message: "Create a client to install a VPN profile on this device."
                    )
                } else {
                    VStack(spacing: 10) {
                        ForEach(viewModel.displayedClientOptions) { option in
                            ClientRow(
                                option: option,
                                isSelected: viewModel.selectedClientId == option.client.clientId,
                                showsOwnerEmail: viewModel.isAdmin,
                                isInstalled: viewModel.isInstalled(option),
                                installState: viewModel.installStateLabel(for: option),
                                tunnelStatus: viewModel.tunnelStatusLabel(for: option),
                                staleText: viewModel.staleText(for: option),
                                toggleIsOn: viewModel.toggleIsOn(for: option),
                                toggleDisabled: viewModel.toggleDisabled(for: option),
                                isToggling: viewModel.isToggling(for: option),
                                installDisabled: viewModel.installDisabled(for: option),
                                deleteDisabled: viewModel.deleteDisabled(for: option),
                                onSelect: {
                                    viewModel.selectedClientId = option.client.clientId
                                },
                                onToggle: { isOn in
                                    viewModel.selectedClientId = option.client.clientId
                                    if isOn {
                                        requestNotificationAuthorization()
                                        if let active = viewModel.activeTunnelClient,
                                           active.client.clientId != option.client.clientId {
                                            Task { await viewModel.switchTunnel(to: option) }
                                        } else {
                                            Task { await viewModel.startTunnel(for: option) }
                                        }
                                    } else {
                                        Task { await viewModel.stopTunnel(for: option) }
                                    }
                                },
                                onInstall: {
                                    viewModel.selectedClientId = option.client.clientId
                                    requestNotificationAuthorization()
                                    Task {
                                        await viewModel.installFromCloud(option)
                                    }
                                },
                                onDelete: {
                                    viewModel.selectedClientId = option.client.clientId
                                    Task { @MainActor in
                                        if await viewModel.isTunnelActiveNow(clientId: option.client.clientId) {
                                            activeTunnelDeleteMessage = CloudGatewayViewModel.activeConfigDeleteMessage
                                        } else {
                                            clientPendingDelete = option
                                        }
                                    }
                                },
                                onDetails: {
                                    clientShowingDetails = option
                                }
                            )
                        }
                    }
                }
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

    private var activeTunnelDeletePresented: Binding<Bool> {
        Binding(
            get: { activeTunnelDeleteMessage != nil },
            set: { isPresented in
                if !isPresented {
                    activeTunnelDeleteMessage = nil
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

    private var guestCreateDisabled: Bool {
        viewModel.isWorking
            || viewModel.selectedRegion == nil
            || viewModel.newClientName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var syncResultPresented: Binding<Bool> {
        Binding(
            get: { viewModel.syncResult != nil },
            set: { isPresented in
                if !isPresented {
                    viewModel.dismissSyncResult()
                }
            }
        )
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

    // Ask for notification permission the first time the user installs or
    // connects a VPN - the dead-tunnel alert only matters once a tunnel exists.
    // iOS prompts only once; later calls are no-ops that keep the current status.
    private func requestNotificationAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func presentDeleteAccount() {
        Task { @MainActor in
            if await viewModel.hasActiveTunnelNow() {
                activeTunnelDeleteMessage = CloudGatewayViewModel.activeAccountDeleteMessage
                return
            }
            viewModel.dismissMessages()
            try? await Task.sleep(nanoseconds: 200_000_000)
            if !viewModel.isWorking {
                isShowingDeleteAccount = true
            }
        }
    }

    private func presentAccountLinking() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            isShowingAccountLinking = true
        }
    }

    private func handleLinkAccountAppleCompletion(_ result: Result<ASAuthorization, Error>) {
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
                await viewModel.linkApple(idToken: idToken, rawNonce: linkAccountAppleRawNonce)
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

    private func handleLinkAccountAppleReauthCompletion(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard
                let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                let tokenData = credential.identityToken,
                let idToken = String(data: tokenData, encoding: .utf8),
                let authorizationCodeData = credential.authorizationCode,
                let authorizationCode = String(data: authorizationCodeData, encoding: .utf8)
            else {
                Task {
                    await viewModel.reportAppleSignInFailure()
                }
                return
            }
            Task {
                await viewModel.completeAccountLinkAppleReauth(
                    idToken: idToken,
                    rawNonce: linkAccountAppleReauthRawNonce,
                    authorizationCode: authorizationCode
                )
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

    private func handleDeleteAccountAppleCompletion(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard
                let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                let tokenData = credential.identityToken,
                let idToken = String(data: tokenData, encoding: .utf8),
                let authorizationCodeData = credential.authorizationCode,
                let authorizationCode = String(data: authorizationCodeData, encoding: .utf8)
            else {
                Task {
                    await viewModel.reportAppleSignInFailure()
                }
                return
            }
            Task {
                await viewModel.deleteAccountWithApple(
                    idToken: idToken,
                    rawNonce: deleteAccountAppleRawNonce,
                    authorizationCode: authorizationCode
                )
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

private struct AccountView: View {
    @Environment(\.cloudGatewayTheme) private var theme
    let email: String?
    let isWorking: Bool
    let canLinkAnotherProvider: Bool
    let onLogout: () -> Void
    let onLinkAnotherProvider: () -> Void
    let onDelete: () -> Void

    var body: some View {
        ZStack {
            theme.page.ignoresSafeArea()

            ThemedPanel {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Account")
                        .font(.title2.bold())
                        .foregroundStyle(theme.content)

                    if let email {
                        Text(email)
                            .font(.subheadline)
                            .foregroundStyle(theme.contentSecondary)
                            .textSelection(.enabled)
                    }

                    Button {
                        onLogout()
                    } label: {
                        Label("Logout", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(isWorking)

                    if canLinkAnotherProvider {
                        Button {
                            onLinkAnotherProvider()
                        } label: {
                            Label("Link another sign-in method", systemImage: "link")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(isWorking)
                    }

                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Label("Delete Account", systemImage: "trash")
                    }
                    .buttonStyle(DangerButtonStyle())
                    .disabled(isWorking)
                }
            }
            .padding(16)
        }
        .presentationDetents([.height(canLinkAnotherProvider ? 340 : 280)])
    }
}

private struct AccountLinkingView: View {
    @ObservedObject var viewModel: CloudGatewayViewModel
    @Binding var appleRawNonce: String
    @Binding var appleReauthRawNonce: String
    let onCancel: () -> Void
    let onAppleLinkCompletion: (Result<ASAuthorization, Error>) -> Void
    let onAppleReauthCompletion: (Result<ASAuthorization, Error>) -> Void
    @Environment(\.cloudGatewayTheme) private var theme

    var body: some View {
        ZStack {
            theme.page.ignoresSafeArea()

            ScrollView {
                ThemedPanel {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Link Sign-In Method")
                                .font(.title2.bold())
                                .foregroundStyle(theme.content)

                            Spacer()

                            Button("Done", action: onCancel)
                                .buttonStyle(NavTextButtonStyle())
                                .disabled(viewModel.isWorking)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Choose a provider to link to your CloudGateway account.")
                            Text("The provider account you link to cannot have an existing CloudGateway account.")
                        }
                        .font(.subheadline)
                        .foregroundStyle(theme.contentSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                        if viewModel.accountLinkReauthMethod == .password {
                            ThemedSecureField(
                                title: "Current password",
                                placeholder: "Enter your current password",
                                text: $viewModel.linkCurrentPassword
                            )
                        } else if viewModel.accountLinkReauthMethod == .apple {
                            appleReauthButton
                        }

                        ForEach(viewModel.missingLinkProviders) { provider in
                            providerControl(provider)
                        }
                    }
                }
                .padding(16)
            }
        }
        .presentationDetents([.height(sheetHeight)])
    }

    private var sheetHeight: CGFloat {
        var height: CGFloat = 250

        switch viewModel.accountLinkReauthMethod {
        case .password:
            height += 94
        case .apple:
            height += 96
        case .none:
            break
        }

        for provider in viewModel.missingLinkProviders {
            switch provider {
            case .password:
                height += 236
            case .google:
                height += 60
            case .apple:
                height += 60
            }
        }

        return min(height, UIScreen.main.bounds.height * 0.82)
    }

    @ViewBuilder
    private func providerControl(_ provider: CloudGatewayAuthProvider) -> some View {
        switch provider {
        case .password:
            VStack(alignment: .leading, spacing: 12) {
                Label("Email and password", systemImage: "key")
                    .font(.headline)
                    .foregroundStyle(theme.content)

                ThemedTextField(
                    title: "Email",
                    placeholder: "you@example.com",
                    text: $viewModel.linkEmail,
                    keyboardType: .emailAddress
                )

                ThemedSecureField(
                    title: "New password",
                    placeholder: "Create a password",
                    text: $viewModel.linkPassword
                )

                Button {
                    Task {
                        await viewModel.linkEmailPassword()
                    }
                } label: {
                    Label("Link email and password", systemImage: "link")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(viewModel.linkPasswordDisabled)
            }
            .padding(12)
            .background(theme.inset)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(theme.edgeSubtle, lineWidth: 1)
            }
        case .google:
            CustomGoogleSignInButton {
                Task {
                    await viewModel.linkGoogle()
                }
            }
            .disabled(viewModel.isWorking)
        case .apple:
            SignInWithAppleButton(.continue) { request in
                let nonce = AppleSignInNonce.randomNonceString()
                appleRawNonce = nonce
                request.nonce = AppleSignInNonce.sha256(nonce)
            } onCompletion: { result in
                onAppleLinkCompletion(result)
            }
            .signInWithAppleButtonStyle(.whiteOutline)
            .frame(height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .disabled(viewModel.isWorking)
        }
    }

    private var appleReauthButton: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sign in with Apple again to continue linking.")
                .font(.subheadline)
                .foregroundStyle(theme.contentSecondary)

            SignInWithAppleButton(.continue) { request in
                let nonce = AppleSignInNonce.randomNonceString()
                appleReauthRawNonce = nonce
                request.nonce = AppleSignInNonce.sha256(nonce)
            } onCompletion: { result in
                onAppleReauthCompletion(result)
            }
            .signInWithAppleButtonStyle(.whiteOutline)
            .frame(height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .disabled(viewModel.isWorking)
        }
    }
}

private struct DeleteAccountView: View {
    @ObservedObject var viewModel: CloudGatewayViewModel
    @Binding var appleRawNonce: String
    let onCancel: () -> Void
    let onAppleCompletion: (Result<ASAuthorization, Error>) -> Void
    @Environment(\.cloudGatewayTheme) private var theme

    var body: some View {
        ZStack {
            theme.page.ignoresSafeArea()

            ScrollView {
                ThemedPanel {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Delete Account?")
                            .font(.title2.bold())
                            .foregroundStyle(theme.content)

                        Text("This will permanently delete your CloudGateway account, VPN clients, stored VPN configuration data, and access records. This cannot be undone.")
                            .foregroundStyle(theme.contentSecondary)
                            .fixedSize(horizontal: false, vertical: true)

                        reauthControl

                        if viewModel.isWorking {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .tint(theme.content)
                                Text("Deleting your account…")
                                    .font(.subheadline)
                                    .foregroundStyle(theme.contentSecondary)
                            }
                        } else if let errorText = viewModel.errorText {
                            Text(errorText)
                                .font(.subheadline)
                                .foregroundStyle(theme.dangerContent)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Button("Cancel") {
                            onCancel()
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(viewModel.isWorking)
                    }
                }
                .padding(16)
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private var reauthControl: some View {
        switch viewModel.accountDeleteReauthMethod {
        case .password:
            VStack(alignment: .leading, spacing: 10) {
                ThemedSecureField(
                    title: "Password",
                    placeholder: "Enter your password",
                    text: $viewModel.deleteAccountPassword
                )

                Button(role: .destructive) {
                    Task {
                        await viewModel.deleteAccountWithPassword()
                    }
                } label: {
                    Label("Delete Account", systemImage: "trash")
                }
                .buttonStyle(DangerButtonStyle())
                .disabled(
                    viewModel.isWorking
                        || viewModel.deleteAccountPassword.isEmpty
                )
            }
        case .apple:
            SignInWithAppleButton(.continue) { request in
                let nonce = AppleSignInNonce.randomNonceString()
                appleRawNonce = nonce
                request.nonce = AppleSignInNonce.sha256(nonce)
            } onCompletion: { result in
                onAppleCompletion(result)
            }
            .signInWithAppleButtonStyle(.whiteOutline)
            .frame(height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .disabled(viewModel.isWorking)
        case .google:
            Button(role: .destructive) {
                Task {
                    await viewModel.deleteAccountWithGoogle()
                }
            } label: {
                Label("Continue with Google", systemImage: "trash")
            }
            .buttonStyle(DangerButtonStyle())
            .disabled(viewModel.isWorking)
        case .unsupported:
            Text("Sign in again before deleting this account.")
                .font(.subheadline)
                .foregroundStyle(theme.dangerContent)
        }
    }
}

private struct AboutView: View {
    @Environment(\.cloudGatewayTheme) private var theme
    @State private var isShowingEmail = false
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
                                            .foregroundStyle(theme.accent)
                                        Link("LinkedIn", destination: URL(string: "https://www.linkedin.com/in/brodsky-alex22/")!)
                                            .foregroundStyle(theme.accent)
                                        Button("Email") {
                                            isShowingEmail = true
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundStyle(theme.accent)
                                        Link("Privacy", destination: URL(string: "https://gocloudlaunch.com/#/privacy/")!)
                                            .foregroundStyle(theme.accent)
                                    }
                                    .font(.caption.weight(.semibold))
                                    .tint(theme.accent)
                                }

                                Text("Create secure **WireGuard VPN** clients on shared CloudGateway servers across multiple regions, ready for both IPv4 and IPv6.")
                                    .foregroundStyle(theme.contentSecondary)
                                Text("Every config comes with built-in ad blocking and encrypted DNS to keep your browsing private.")
                                    .foregroundStyle(theme.contentSecondary)
                                Text("Create a config in your chosen region and install it on your device in just a few taps.")
                                    .foregroundStyle(theme.contentSecondary)
                                Text("**Secure, simple, and instant.** Your personal VPN clients, managed on demand.")
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
        .sheet(isPresented: $isShowingEmail) {
            EmailContactView()
        }
    }
}

private struct EmailContactView: View {
    @Environment(\.cloudGatewayTheme) private var theme

    var body: some View {
        ZStack {
            theme.page.ignoresSafeArea()

            ThemedPanel {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Email")
                        .font(.title2.bold())
                        .foregroundStyle(theme.content)

                    Text("Brodsky.Alex22@gmail.com")
                        .font(.headline)
                        .foregroundStyle(theme.contentSecondary)
                        .textSelection(.enabled)

                    Link(destination: URL(string: "mailto:Brodsky.Alex22@gmail.com")!) {
                        Label("Open Mail", systemImage: "envelope")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
            }
            .padding(16)
        }
        .presentationDetents([.height(240)])
    }
}

private struct SignedInRequiredView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.cloudGatewayTheme) private var theme
    let onSignIn: () -> Void

    var body: some View {
        ZStack {
            theme.page.ignoresSafeArea()

            ThemedPanel {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Sign in required")
                        .font(.title2.bold())
                        .foregroundStyle(theme.content)

                    Text("Creating VPN clients is restricted to signed-in users.")
                        .foregroundStyle(theme.contentSecondary)

                    Button("Sign in") {
                        onSignIn()
                    }
                    .buttonStyle(PrimaryButtonStyle())

                    Button("Not now") {
                        dismiss()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
            .padding(16)
        }
        .presentationDetents([.height(280)])
    }
}

private struct ClientDetailsView: View {
    @Environment(\.cloudGatewayTheme) private var theme
    let option: CloudGatewayClientOption
    @State private var didCopy = false

    var body: some View {
        ZStack {
            theme.page.ignoresSafeArea()

            ThemedPanel {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(option.client.displayName)
                            .font(.title2.bold())
                            .foregroundStyle(theme.content)

                        Spacer()

                        Button(action: copyAllDetails) {
                            Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(IconSecondaryButtonStyle())
                        .accessibilityLabel("Copy details")
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        DetailLine(label: "VPN id", value: option.client.clientId, selectable: false)
                        DetailLine(label: "Region id", value: option.client.regionId, selectable: false)
                        DetailLine(label: "Tunnel IP", value: tunnelIP, selectable: false)
                        DetailLine(label: "Connection URL", value: endpoint, selectable: false)
                        DetailLine(label: "Owner email", value: option.client.ownerEmail ?? "Unknown", selectable: false)
                    }
                }
                // Hold anywhere on the card to copy every detail at once.
                .contentShape(Rectangle())
                .onLongPressGesture { copyAllDetails() }
            }
            .padding(16)
        }
        .presentationDetents([.medium])
    }

    private var endpoint: String {
        if let hostname = option.client.serverEndpointHostname, !hostname.isEmpty {
            return hostname
        }
        if let ipv4 = option.client.serverEndpointIpv4, !ipv4.isEmpty {
            return ipv4
        }
        return "Unavailable"
    }

    private var tunnelIP: String {
        guard let address = option.client.assignedTunnelIpv4,
              let host = address.split(separator: "/").first,
              !host.isEmpty else {
            return "Unavailable"
        }
        return String(host)
    }

    private var detailsText: String {
        """
        \(option.client.displayName)

        VPN id: \(option.client.clientId)
        Region id: \(option.client.regionId)
        Tunnel IP: \(tunnelIP)
        Connection URL: \(endpoint)
        Owner email: \(option.client.ownerEmail ?? "Unknown")
        """
    }

    private func copyAllDetails() {
        UIPasteboard.general.string = detailsText
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation { didCopy = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation { didCopy = false }
        }
    }
}

private struct SyncResultView: View {
    @Environment(\.cloudGatewayTheme) private var theme
    let result: CloudGatewaySyncResult

    var body: some View {
        ZStack {
            theme.page.ignoresSafeArea()

            ThemedPanel {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Sync Results")
                        .font(.title2.bold())
                        .foregroundStyle(theme.content)

                    VStack(alignment: .leading, spacing: 8) {
                        DetailLine(label: "Region", value: result.regionId)
                        DetailLine(label: "Synced at", value: result.syncedAt)
                        DetailLine(label: "Summary", value: "added=\(result.added) updated=\(result.updated) removed=\(result.removed)")
                    }

                    ScrollView {
                        Text(result.log)
                            .font(.caption.monospaced())
                            .foregroundStyle(theme.contentSecondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: .infinity)
                    .padding(10)
                    .background(theme.inset)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    ShareLink(item: result.logText) {
                        Label("Download Logs", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
            }
            .padding(16)
        }
        .presentationDetents([.medium, .large])
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
    @State private var isRevealingPassword = false
    let title: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(theme.contentSecondary)

            HStack(spacing: 10) {
                passwordField

                Button {
                    isRevealingPassword.toggle()
                } label: {
                    Image(systemName: isRevealingPassword ? "eye.slash" : "eye")
                        .imageScale(.medium)
                        .foregroundStyle(theme.contentMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isRevealingPassword ? "Hide password" : "Show password")
            }
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

    @ViewBuilder
    private var passwordField: some View {
        if isRevealingPassword {
            TextField(placeholder, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } else {
            SecureField(placeholder, text: $text)
        }
    }
}

private struct RegionButton: View {
    @Environment(\.cloudGatewayTheme) private var theme
    let region: CloudGatewayRegion
    let isSelected: Bool
    let showsCapacity: Bool
    let isLoading: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(region.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isSelected ? theme.accent : theme.contentSecondary)
                if showsCapacity {
                    Text(capacityText)
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

    private var capacityText: String {
        if let capacity = region.capacity, capacity.isKnown {
            return capacity.displayText
        }
        // Capacity is fetched after the region list; stay neutral while it loads
        // instead of flashing an "unavailable" error.
        return isLoading ? "Checking capacity..." : "Capacity unavailable"
    }

    private var capacityColor: Color {
        if let capacity = region.capacity, capacity.isKnown {
            return capacity.isAtCapacity ? theme.dangerContent : theme.contentMuted
        }
        return isLoading ? theme.contentMuted : theme.dangerContent
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
    let isLoading: Bool

    var body: some View {
        if let capacity = region.capacity, capacity.isKnown {
            if capacity.isAtCapacity {
                Text("\(region.displayName) is currently full. Choose another region before creating a client.")
                    .font(.subheadline)
                    .foregroundStyle(theme.dangerContent)
            }
        } else if isLoading {
            // Capacity is still being fetched during load; don't alarm the user
            // with an "unavailable" warning until the load actually finishes.
            Text("Checking capacity for \(region.displayName)...")
                .font(.subheadline)
                .foregroundStyle(theme.contentMuted)
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
    let showsOwnerEmail: Bool
    let isInstalled: Bool
    let installState: String?
    let tunnelStatus: String?
    let staleText: String?
    let toggleIsOn: Bool
    let toggleDisabled: Bool
    let isToggling: Bool
    let installDisabled: Bool
    let deleteDisabled: Bool
    let onSelect: () -> Void
    let onToggle: (Bool) -> Void
    let onInstall: () -> Void
    let onDelete: () -> Void
    let onDetails: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: onSelect) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(option.client.displayName)
                            .font(.headline)
                            .foregroundStyle(theme.content)
                        if showsOwnerEmail {
                            Text(option.client.ownerEmail ?? "Unknown owner")
                                .font(.subheadline)
                                .foregroundStyle(theme.contentMuted)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    if let installState {
                        Text(installState)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(theme.accentStrong)
                    }
                }
            }
            .buttonStyle(.plain)

            HStack(spacing: 12) {
                if isInstalled {
                    Toggle("VPN", isOn: Binding(
                        get: { toggleIsOn },
                        set: onToggle
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(theme.primary)
                    .disabled(toggleDisabled)

                    if isToggling {
                        ProgressView()
                            .controlSize(.small)
                            .tint(theme.contentMuted)
                    } else if let tunnelStatus {
                        Text(tunnelStatus)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(theme.contentSecondary)
                    }

                    Spacer()
                } else {
                    Button("Install", action: onInstall)
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(installDisabled)

                    Spacer()
                }

                Button(action: onDetails) {
                    Image(systemName: "ellipsis")
                }
                .buttonStyle(IconSecondaryButtonStyle())
                .accessibilityLabel("Show \(option.client.displayName) details")

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(IconDangerButtonStyle())
                .disabled(deleteDisabled)
                .accessibilityLabel("Delete \(option.client.displayName)")
            }

            if let staleText {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .imageScale(.small)
                        .accessibilityHidden(true)
                    Text(staleText)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(theme.warningStrong)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Warning: \(staleText)")
            }
        }
        .padding(12)
        .background(isSelected ? theme.inset : theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isSelected ? theme.primarySoftEdge : theme.edgeFaint, lineWidth: 1)
        }
        // Hold anywhere on the card - including empty background - to open
        // details. simultaneousGesture keeps the toggle and buttons tappable.
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .simultaneousGesture(LongPressGesture().onEnded { _ in onDetails() })
    }
}

private struct CustomGoogleSignInButton: View {
    @Environment(\.cloudGatewayTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image("GoogleLogo")
                    .renderingMode(.original)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)
                    .opacity(isEnabled ? 1 : 0.4)

                Text("Sign in with Google")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isEnabled ? theme.content : theme.contentDisabled)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .buttonStyle(WebGoogleButtonStyle())
        .accessibilityLabel("Sign in with Google")
    }
}

private struct WebGoogleButtonStyle: ButtonStyle {
    @Environment(\.cloudGatewayTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(isEnabled ? (configuration.isPressed ? theme.insetStrong : theme.inset) : theme.disabled)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(theme.edge, lineWidth: 1)
            }
    }
}

private struct DetailLine: View {
    @Environment(\.cloudGatewayTheme) private var theme
    let label: String
    let value: String
    var selectable: Bool = true

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                labelText
                Spacer()
                valueText(alignment: .trailing, wraps: false)
            }

            VStack(alignment: .leading, spacing: 3) {
                labelText
                valueText(alignment: .trailing, wraps: true)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private var labelText: some View {
        Text(label)
            .font(.caption)
            .foregroundStyle(theme.contentFaint)
    }

    @ViewBuilder
    private func valueText(alignment: TextAlignment, wraps: Bool) -> some View {
        let text = Text(value)
            .font(.subheadline)
            .foregroundStyle(theme.contentSecondary)
            .multilineTextAlignment(alignment)
            .lineLimit(wraps ? nil : 1)
            .fixedSize(horizontal: !wraps, vertical: true)
        if selectable {
            text.textSelection(.enabled)
        } else {
            text.textSelection(.disabled)
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
    let actionTitle: String?
    let onAction: (() -> Void)?

    init(
        text: String,
        style: MessageBannerStyle,
        onDismiss: (() -> Void)?,
        actionTitle: String? = nil,
        onAction: (() -> Void)? = nil
    ) {
        self.text = text
        self.style = style
        self.onDismiss = onDismiss
        self.actionTitle = actionTitle
        self.onAction = onAction
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(foregroundColor)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let actionTitle, let onAction {
                Button(actionTitle, action: onAction)
                    .buttonStyle(.plain)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(foregroundColor)
            }

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

private struct IconSecondaryButtonStyle: ButtonStyle {
    @Environment(\.cloudGatewayTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .frame(width: 38, height: 38)
            .background(isEnabled ? (configuration.isPressed ? theme.insetStrongHover : theme.insetStrong) : theme.disabled)
            .foregroundStyle(isEnabled ? theme.contentSecondary : theme.contentDisabled)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct IconDangerButtonStyle: ButtonStyle {
    @Environment(\.cloudGatewayTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .frame(width: 38, height: 38)
            .background(isEnabled ? (configuration.isPressed ? theme.dangerButtonHover : theme.dangerButton) : theme.disabled)
            .foregroundStyle(isEnabled ? theme.content : theme.contentDisabled)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

#Preview {
    ContentView()
        .environment(\.cloudGatewayTheme, CloudGatewayTheme())
        .preferredColorScheme(.dark)
}
