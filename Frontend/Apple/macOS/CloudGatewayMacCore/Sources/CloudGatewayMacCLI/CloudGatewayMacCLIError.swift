import CloudGatewayMacControllerIPC
import CloudGatewayMacCore
import Foundation

struct CloudGatewayMacCLIError: Error, Sendable {
    enum Code: String {
        case usage, internalError = "internal_error", notImplemented = "not_implemented"
        case invalidResponse = "invalid_response"
        case signInRequired = "sign_in_required", accessDenied = "access_denied"
        case setupRequired = "setup_required", credentialsUnavailable = "credentials_unavailable"
        case incompatibleVersion = "incompatible_version", untrustedBuild = "untrusted_build"
        case installationRequired = "installation_required", controllerUnavailable = "controller_unavailable"
        case controllerRejected = "controller_rejected"
        case configUnavailable = "config_unavailable", selectionUnavailable = "selection_unavailable"
        case clientActive = "client_active"
        case networkUnavailable = "network_unavailable"
        case refreshSkipped = "refresh_skipped", refreshSuperseded = "refresh_superseded", interrupted
        case busy
        case timeout, stopTimedOut = "stop_timed_out"
        case vpnFailed = "vpn_failed", commandFailed = "command_failed"
        case extensionMismatch = "extension_mismatch", initialSetupRequired = "initial_setup_required"
        case extensionReplacementBlocked = "extension_replacement_blocked"
        case approvalRequired = "approval_required", restartRequired = "restart_required"
        case invalidBundle = "invalid_bundle", checkingReadiness = "checking_readiness"
        case activationFailed = "activation_failed", readinessFailed = "readiness_failed"
        case disconnectRequired = "disconnect_required", storageUnavailable = "storage_unavailable"
        case observationUnavailable = "observation_unavailable"
        case updateSuperseded = "update_superseded", reconnectSuppressed = "reconnect_suppressed"
        case operationUnknown = "operation_unknown", operationExpired = "operation_expired"

        var exitCode: Int32 {
            switch self {
            case .internalError, .notImplemented, .invalidResponse: 1
            case .usage: 2
            case .signInRequired, .accessDenied: 3
            case .setupRequired, .credentialsUnavailable, .incompatibleVersion, .untrustedBuild,
                 .installationRequired, .controllerUnavailable, .controllerRejected,
                 .extensionMismatch, .extensionReplacementBlocked, .initialSetupRequired, .approvalRequired, .restartRequired,
                 .invalidBundle, .checkingReadiness, .disconnectRequired, .clientActive: 4
            case .configUnavailable, .selectionUnavailable: 5
            case .networkUnavailable, .refreshSkipped, .storageUnavailable, .observationUnavailable: 6
            case .busy, .refreshSuperseded: 7
            case .timeout, .stopTimedOut: 8
            case .vpnFailed, .commandFailed, .activationFailed, .readinessFailed: 9
            case .operationUnknown, .operationExpired, .updateSuperseded, .reconnectSuppressed: 10
            case .interrupted: 130
            }
        }

        fileprivate var defaults: (message: String, suggestion: String?) {
            switch self {
            case .usage: ("Invalid command line", "Run: cloudgateway help")
            case .internalError: ("CloudGateway hit an unexpected error", nil)
            case .notImplemented: ("This command is not available in this build yet", nil)
            case .invalidResponse: ("The controller returned an invalid response", "Try again. Reopen CloudGateway if this continues")
            case .signInRequired: ("Sign-in required", "Run: cloudgateway auth login")
            case .accessDenied: ("Account access was denied", "Sign in again after access is restored")
            case .setupRequired: ("VPN setup is not finished", "Open CloudGateway on this Mac to finish setup")
            case .credentialsUnavailable: ("Saved credentials or secure storage are unavailable",
                                           "Unlock this Mac's login session, then try again")
            case .incompatibleVersion: ("CloudGateway is updating, or this copy does not match the installed app",
                                        "Wait for the update to finish, then run the installed CloudGateway")
            case .untrustedBuild: ("CloudGateway could not verify its running build", "Reinstall CloudGateway in /Applications")
            case .installationRequired: ("CloudGateway must be installed in /Applications", "Move CloudGateway to /Applications, then try again")
            case .controllerUnavailable: ("Unable to reach the CloudGateway controller", "Open CloudGateway once on this Mac, then try again")
            case .controllerRejected: ("The CloudGateway controller rejected this request", "Run the command as the macOS user who set up CloudGateway")
            case .configUnavailable: ("That config is missing or unusable", "Run: cloudgateway list")
            case .selectionUnavailable: ("No usable config is selected", "Run cloudgateway ls, then cloudgateway up <client-uuid>")
            case .clientActive: ("That client still has an active VPN profile", "Disconnect that client and wait for it to stop before removing it")
            case .networkUnavailable: ("Unable to reach CloudGateway", "Check the network connection, then try again")
            case .refreshSkipped: ("Inventory refresh did not run", "Run: cloudgateway refresh")
            case .refreshSuperseded: ("Another operation superseded this inventory refresh", "Run: cloudgateway refresh")
            case .interrupted: ("The caller was interrupted", nil)
            case .busy: ("Another operation is in progress", "Wait for it to finish, then try again")
            case .timeout: ("The command did not finish before its deadline", "Try again with a longer --timeout")
            case .stopTimedOut: ("The VPN has not confirmed stop", "Run: cloudgateway status")
            case .vpnFailed: ("The VPN operation failed", "Run: cloudgateway status")
            case .commandFailed: ("The command failed", "Run: cloudgateway status")
            case .extensionMismatch: ("The running VPN extension does not match the installed app", "Run: cloudgateway update")
            case .extensionReplacementBlocked: ("The running VPN extension has the installed version and build number but different code, so macOS will not replace it",
                                                "Install a CloudGateway build with a higher VPN extension build number, then run: cloudgateway update")
            case .initialSetupRequired: ("Initial VPN setup is required", "Open CloudGateway on this Mac to finish initial setup")
            case .approvalRequired: ("macOS approval is required for the VPN extension",
                                     "Approve CloudGateway in System Settings on this Mac, then check the operation")
            case .restartRequired: ("macOS must restart to finish the VPN extension update",
                                    "Restart this Mac, then check the operation. The controller resumes when next started")
            case .invalidBundle: ("The installed VPN extension bundle is invalid", "Reinstall CloudGateway in /Applications")
            case .checkingReadiness: ("CloudGateway is still checking VPN extension readiness", "Run: cloudgateway status")
            case .activationFailed: ("macOS could not activate the VPN extension", "Run: cloudgateway doctor")
            case .readinessFailed: ("The updated VPN extension did not pass authenticated readiness checks", "Run: cloudgateway doctor")
            case .disconnectRequired: ("Updating the VPN extension requires stopping the active VPN",
                                       "Run: cloudgateway update --allow-disconnect. This can disconnect SSH if it uses the VPN")
            case .storageUnavailable: ("CloudGateway could not persist the update safely", "Check this Mac's available storage and permissions")
            case .observationUnavailable: ("CloudGateway cannot observe the current VPN profiles", "Run: cloudgateway status")
            case .updateSuperseded: ("The installed app changed during this update", "Check the operation before requesting another update")
            case .reconnectSuppressed: ("The VPN update did not reconnect because its original connection is no longer authorized",
                                       "Check the current VPN state and account before requesting a start")
            case .operationUnknown: ("The operation result is unknown or no longer retained",
                                     "Run cloudgateway status before trying again")
            case .operationExpired: ("The operation expired before it ran", "Run the command again")
            }
        }
    }

    let code: Code
    let message: String
    let suggestion: String?
    var data: CloudGatewayMacCLIData?
    var operationId: UUID?

    init(_ code: Code, message: String? = nil, suggestion: String? = nil, data: CloudGatewayMacCLIData? = nil) {
        self.code = code
        self.message = message ?? code.defaults.message
        self.suggestion = suggestion ?? code.defaults.suggestion
        self.data = data
    }

    init(commandFailure failure: CloudGatewayMacCommandFailure) {
        switch failure {
        case .signInRequired: self.init(Code.signInRequired)
        case .accessDenied: self.init(Code.accessDenied)
        case .setupRequired: self.init(Code.setupRequired)
        case .extensionMismatch: self.init(Code.extensionMismatch)
        case .initialSetupRequired: self.init(Code.initialSetupRequired)
        case .approvalRequired: self.init(Code.approvalRequired)
        case .restartRequired: self.init(Code.restartRequired)
        case .invalidBundle: self.init(Code.invalidBundle)
        case .checkingReadiness: self.init(Code.checkingReadiness)
        case .activationFailed: self.init(Code.activationFailed)
        case .credentialsUnavailable: self.init(Code.credentialsUnavailable)
        case .incompatibleVersion: self.init(Code.incompatibleVersion)
        case .configUnavailable: self.init(Code.configUnavailable)
        case .selectionUnavailable: self.init(Code.selectionUnavailable)
        case .clientActive: self.init(Code.clientActive)
        case .networkUnavailable: self.init(Code.networkUnavailable)
        case .busy: self.init(Code.busy)
        case .stopTimedOut: self.init(Code.stopTimedOut)
        case .vpnFailed: self.init(Code.vpnFailed)
        case .internalError: self.init(Code.internalError)
        }
    }

    init(updateFailure failure: CloudGatewayMacManagedUpdateFailure) {
        switch failure {
        case .disconnectRequired: self.init(Code.disconnectRequired)
        case .initialSetupRequired: self.init(Code.initialSetupRequired)
        case .approvalRequired: self.init(Code.approvalRequired)
        case .restartRequired: self.init(Code.restartRequired)
        case .invalidBundle: self.init(Code.invalidBundle)
        case .storageUnavailable: self.init(Code.storageUnavailable)
        case .configUnavailable: self.init(Code.configUnavailable)
        case .signInRequired: self.init(Code.signInRequired)
        case .accessDenied: self.init(Code.accessDenied)
        case .networkUnavailable: self.init(Code.networkUnavailable)
        case .busy: self.init(Code.busy)
        case .timeout: self.init(Code.timeout)
        case .stopTimedOut: self.init(Code.stopTimedOut)
        case .activationFailed: self.init(Code.activationFailed)
        case .readinessFailed: self.init(Code.readinessFailed)
        case .superseded, .targetChanged: self.init(Code.updateSuperseded)
        case .reconnectSuppressed: self.init(Code.reconnectSuppressed)
        case .observationUnavailable: self.init(Code.observationUnavailable)
        case .confirmationExpired: self.init(Code.operationExpired)
        case .vpnFailed: self.init(Code.vpnFailed)
        case .replacementBlocked: self.init(Code.extensionReplacementBlocked)
        }
    }

    init(controllerFailure failure: CloudGatewayMacControllerFailure) {
        switch failure {
        case .invalidRequest: self.init(Code.invalidResponse)
        case .incompatibleVersion: self.init(Code.incompatibleVersion)
        case .unavailable: self.init(Code.controllerUnavailable)
        case .timeout: self.init(Code.timeout)
        case .busy: self.init(Code.busy)
        case .rejected: self.init(Code.controllerRejected)
        case .outcomeUnknown: self.init(Code.operationUnknown)
        case .extensionAttemptChanged: self.init(Code.setupRequired, message: "The VPN extension update changed")
        case .preparationExpired: self.init(Code.operationExpired)
        case .commandFailed: self.init(Code.commandFailed)
        case .authCleanupFailed: self.init(Code.credentialsUnavailable, message: "Sign-out cleanup did not finish")
        }
    }

    // Raw errors never reach output, only their stable category
    init(_ error: any Error) {
        switch error {
        case let error as Self: self = error
        case let failure as CloudGatewayMacControllerFailure: self.init(controllerFailure: failure)
        case let failure as CloudGatewayMacManagedUpdateFailure: self.init(updateFailure: failure)
        case is CancellationError: self.init(.interrupted)
        case CloudGatewayMacControllerLaunchError.installationRequired, CloudGatewayMacControllerLaunchError.unsafeLocation:
            self.init(.installationRequired)
        case is CloudGatewayMacControllerLaunchError: self.init(.controllerUnavailable)
        default: self.init(.internalError)
        }
    }
}
