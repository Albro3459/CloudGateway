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
        case networkUnavailable = "network_unavailable"
        case refreshSkipped = "refresh_skipped", refreshSuperseded = "refresh_superseded", interrupted
        case busy
        case timeout, stopTimedOut = "stop_timed_out"
        case vpnFailed = "vpn_failed", commandFailed = "command_failed"
        case operationUnknown = "operation_unknown", operationExpired = "operation_expired"

        var exitCode: Int32 {
            switch self {
            case .internalError, .notImplemented, .invalidResponse: 1
            case .usage: 2
            case .signInRequired, .accessDenied: 3
            case .setupRequired, .credentialsUnavailable, .incompatibleVersion, .untrustedBuild,
                 .installationRequired, .controllerUnavailable, .controllerRejected: 4
            case .configUnavailable, .selectionUnavailable: 5
            case .networkUnavailable, .refreshSkipped: 6
            case .busy, .refreshSuperseded: 7
            case .timeout, .stopTimedOut: 8
            case .vpnFailed, .commandFailed: 9
            case .operationUnknown, .operationExpired: 10
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
            case .selectionUnavailable: ("No usable config is selected", "Run cloudgateway list, then cloudgateway up <config-id>")
            case .networkUnavailable: ("Unable to reach CloudGateway", "Check the network connection, then try again")
            case .refreshSkipped: ("Inventory refresh did not run", "Run: cloudgateway refresh")
            case .refreshSuperseded: ("Another operation superseded this inventory refresh", "Run: cloudgateway refresh")
            case .interrupted: ("The caller was interrupted", nil)
            case .busy: ("Another operation is in progress", "Wait for it to finish, then try again")
            case .timeout: ("The command did not finish before its deadline", "Try again with a longer --timeout")
            case .stopTimedOut: ("The VPN has not confirmed stop", "Run: cloudgateway status")
            case .vpnFailed: ("The VPN operation failed", "Run: cloudgateway status")
            case .commandFailed: ("The command failed", "Run: cloudgateway status")
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

    init(_ failure: CloudGatewayMacCommandFailure) {
        switch failure {
        case .signInRequired: self.init(Code.signInRequired)
        case .accessDenied: self.init(Code.accessDenied)
        case .setupRequired: self.init(Code.setupRequired)
        case .credentialsUnavailable: self.init(Code.credentialsUnavailable)
        case .incompatibleVersion: self.init(Code.incompatibleVersion)
        case .configUnavailable: self.init(Code.configUnavailable)
        case .selectionUnavailable: self.init(Code.selectionUnavailable)
        case .networkUnavailable: self.init(Code.networkUnavailable)
        case .busy: self.init(Code.busy)
        case .stopTimedOut: self.init(Code.stopTimedOut)
        case .vpnFailed: self.init(Code.vpnFailed)
        case .internalError: self.init(Code.internalError)
        }
    }

    init(_ failure: CloudGatewayMacControllerFailure) {
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
        case let failure as CloudGatewayMacControllerFailure: self.init(failure)
        case is CancellationError: self.init(.interrupted)
        case CloudGatewayMacControllerLaunchError.installationRequired, CloudGatewayMacControllerLaunchError.unsafeLocation:
            self.init(.installationRequired)
        case is CloudGatewayMacControllerLaunchError: self.init(.controllerUnavailable)
        default: self.init(.internalError)
        }
    }
}
