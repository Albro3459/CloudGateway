import CloudGatewayKit
import CloudGatewayMacControllerIPC
import CloudGatewayMacCore
import Foundation

// Public JSON schema version 1. These types own the field names, so internal Codable changes cannot leak into output
struct CloudGatewayMacCLIRecord: Encodable {
    enum Kind: String, Encodable {
        case accepted, result, error
    }

    struct Failure: Encodable {
        let code: String
        let message: String
        @CloudGatewayMacCLINullable var suggestion: String?

        init(_ error: CloudGatewayMacCLIError) {
            code = error.code.rawValue
            message = CloudGatewayMacCLIText.sanitize(error.message)
            suggestion = error.suggestion
        }
    }

    let schemaVersion = 1
    let type: Kind
    @CloudGatewayMacCLINullable var command: String?
    @CloudGatewayMacCLINullable var operationId: String?
    @CloudGatewayMacCLINullable var data: CloudGatewayMacCLIData?
    @CloudGatewayMacCLINullable var error: Failure?

    func line() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(self), as: UTF8.self) + "\n"
    }
}

indirect enum CloudGatewayMacCLIData: Encodable, Sendable {
    case help(CloudGatewayMacCLIHelp)
    case version(CloudGatewayMacCLIVersion)
    case auth(CloudGatewayMacCLIAuthStatus)
    case status(CloudGatewayMacCLIStatus)
    case inventory(CloudGatewayMacCLIInventory)
    case mutation(CloudGatewayMacCLIMutation)
    case refresh(CloudGatewayMacCLIRefresh)
    case doctor(CloudGatewayMacCLIDoctorReport)

    func encode(to encoder: any Encoder) throws {
        switch self {
        case .help(let value): try value.encode(to: encoder)
        case .version(let value): try value.encode(to: encoder)
        case .auth(let value): try value.encode(to: encoder)
        case .status(let value): try value.encode(to: encoder)
        case .inventory(let value): try value.encode(to: encoder)
        case .mutation(let value): try value.encode(to: encoder)
        case .refresh(let value): try value.encode(to: encoder)
        case .doctor(let value): try value.encode(to: encoder)
        }
    }
}

@propertyWrapper
struct CloudGatewayMacCLINullable<Value: Encodable & Sendable>: Encodable, Sendable {
    var wrappedValue: Value?

    init(wrappedValue: Value?) { self.wrappedValue = wrappedValue }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        if let wrappedValue { try container.encode(wrappedValue) }
        else { try container.encodeNil() }
    }
}

struct CloudGatewayMacCLIHelp: Encodable {
    struct Command: Encodable {
        let name: String
        @CloudGatewayMacCLINullable var arguments: String?
        let summary: String
    }

    struct Option: Encodable {
        let flags: [String]
        @CloudGatewayMacCLINullable var value: String?
        let summary: String

        init(_ option: CloudGatewayMacCLIOption) {
            flags = option.flags
            value = option.valueName
            summary = option.summary
        }
    }

    @CloudGatewayMacCLINullable var topic: String?
    let usage: String
    let summary: String
    let commands: [Command]
    let options: [Option]
    let commonOptions: [Option]
    let notes: [String]
    let examples: [String]

    init(_ topic: CloudGatewayMacCLITopic) {
        self.topic = topic.kind == .root ? nil : topic.name
        usage = topic.usage
        summary = topic.summary
        commands = topic.subtopics.map { Command(name: $0.name, arguments: $0.arguments, summary: $0.summary) }
        options = topic.options.map(Option.init)
        commonOptions = CloudGatewayMacCLIOption.common.map(Option.init)
        notes = topic.notes
        examples = topic.examples
    }
}

struct CloudGatewayMacCLIVersion: Encodable {
    let version: String
    let build: String
}

struct CloudGatewayMacCLIAuthStatus: Encodable {
    enum State: String, Encodable {
        case signedOut = "signed_out", retained, restoring, online, offline, denied
    }

    enum Access: String, Encodable {
        case unverified, checking, online, offline, denied, unreachable
    }

    enum Credentials: String, Encodable {
        case available, unknown
    }

    let state: State
    @CloudGatewayMacCLINullable var accountId: String?
    let retainedSession: Bool
    let access: Access
    let credentials: Credentials
    let loginPending: Bool

    init(_ state: CloudGatewayMacControllerState) {
        if state.accountId != nil { self.state = state.access == .offline ? .offline : .online }
        else if state.isPendingRestoration { self.state = .restoring }
        else if state.access == .denied { self.state = .denied }
        else { self.state = state.hasRetainedSession ? .retained : .signedOut }
        accountId = state.accountId
        retainedSession = state.hasRetainedSession
        access = switch state.access {
        case .unverified: .unverified
        case .checking: .checking
        case .online: .online
        case .offline: .offline
        case .denied: .denied
        case .unreachable: .unreachable
        }
        credentials = state.credentials == .available ? .available : .unknown
        loginPending = switch state.auth {
        case .requestingCode, .waitingForApproval, .exchangingToken: true
        case .signedOut, .signedIn, .failed: false
        }
    }
}

struct CloudGatewayMacCLIStatus: Encodable {
    struct Tunnel: Encodable {
        enum State: String, Encodable {
            case disconnected, connecting, connected, disconnecting, unknown
        }

        enum Observation: String, Encodable {
            case current, stale, unavailable

            init(_ state: CloudGatewayMacControllerState) {
                self = state.observationAvailable ? .current : state.profilesObservedAt == nil ? .unavailable : .stale
            }
        }

        let state: State
        let observation: Observation
        @CloudGatewayMacCLINullable var observedAt: Date?
        @CloudGatewayMacCLINullable var configId: String?

        // Signed-out and other-account profiles keep their state but never their ID
        init(_ state: CloudGatewayMacControllerState) {
            self.init(state.status, observation: Observation(state))
            observedAt = state.profilesObservedAt
            configId = state.observedProfiles.first {
                $0.status != .disconnected && $0.status != .invalid
            }?.identifier
        }

        init(_ status: CloudGatewayMacControllerStatus) {
            self.init(status, observation: status.observationAvailable ? .current : status.needsStop ? .stale : .unavailable)
        }

        private init(_ status: CloudGatewayMacControllerStatus, observation: Observation) {
            self.observation = observation
            state = switch status.phase {
            case _ where observation == .unavailable: .unknown
            case .disconnected: .disconnected
            case .connecting: .connecting
            case .connected: .connected
            case .disconnecting: .disconnecting
            }
        }
    }

    let tunnel: Tunnel
    @CloudGatewayMacCLINullable var operation: CloudGatewayMacCLIOperation?
    var update: CloudGatewayMacCLIUpdate? = nil
}

struct CloudGatewayMacCLIOperation: Encodable {
    enum State: String, Encodable {
        case accepted, running, completed, failed, unknown
    }

    enum Result: String, Encodable {
        case startRequested = "start_requested", alreadyActive = "already_active", completed, failed, unknown, expired
    }

    enum Warning: String, Encodable {
        case selectionNotSaved = "selection_not_saved", inventoryNotRefreshed = "inventory_not_refreshed"
        case localCleanupIncomplete = "local_cleanup_incomplete"
        case reconnectSuppressionNotPersisted = "reconnect_suppression_not_persisted"
    }

    let id: String
    let state: State
    @CloudGatewayMacCLINullable var result: Result?
    @CloudGatewayMacCLINullable var configId: String?
    @CloudGatewayMacCLINullable var warning: Warning?
    @CloudGatewayMacCLINullable var error: CloudGatewayMacCLIRecord.Failure?
    let failure: CloudGatewayMacCLIError?

    private enum CodingKeys: String, CodingKey {
        case id, state, result, configId, warning, error
    }

    // The controller hides account-bound outcomes from other sessions, so only the coarse state remains
    init(_ operation: CloudGatewayMacControllerOperation, outcome: CloudGatewayMacCommandOutcome?) {
        id = operation.id.uuidString.lowercased()
        state = switch operation.state {
        case .accepted: .accepted
        case .running: .running
        case .completed: .completed
        case .failed: .failed
        case .unknown: .unknown
        }
        var failure: CloudGatewayMacCLIError?
        warning = operation.warning.map(Self.warning)
        switch outcome {
        case .startRequested(let identifier, let warning):
            result = .startRequested
            configId = identifier
            self.warning = warning.map(Self.warning)
        case .alreadyActive(let identifier, let warning):
            result = .alreadyActive
            configId = identifier
            self.warning = warning.map(Self.warning)
        case .completed(let warning):
            result = .completed
            self.warning = warning.map(Self.warning)
        case .failed(let reason):
            result = .failed
            failure = .init(commandFailure: reason)
        case .unknown:
            result = .unknown
            failure = .init(.operationUnknown)
        case .expired:
            result = .expired
            failure = .init(.operationExpired)
        case nil:
            if operation.state == .failed { failure = .init(controllerFailure: operation.failure ?? .commandFailed) }
            else if operation.state == .unknown { failure = .init(controllerFailure: operation.failure ?? .outcomeUnknown) }
        }
        self.failure = failure
        error = failure.map(CloudGatewayMacCLIRecord.Failure.init)
    }

    private static func warning(_ warning: CloudGatewayMacCommandWarning) -> Warning {
        switch warning {
        case .selectionNotSaved: .selectionNotSaved
        case .inventoryNotRefreshed: .inventoryNotRefreshed
        case .localCleanupIncomplete: .localCleanupIncomplete
        case .reconnectSuppressionNotPersisted: .reconnectSuppressionNotPersisted
        }
    }
}

struct CloudGatewayMacCLIInventory: Encodable {
    enum Scope: String, Encodable {
        case authorized, installed
    }

    enum Freshness: String, Encodable {
        case current, cached, stale
    }

    struct Region: Encodable {
        let regionId: String
        let name: String
        let configs: [Config]
    }

    struct Config: Encodable {
        enum CloudState: String, Encodable {
            case creating, active, failed, removed
        }

        enum Eligibility: String, Encodable {
            case eligible, inactive, configMissing = "config_missing", regionUnavailable = "region_unavailable"
        }

        enum Source: String, Encodable {
            case cloud, cache
        }

        enum Tunnel: String, Encodable {
            case invalid, disconnected, connecting, connected, reasserting, disconnecting
        }

        let configId: String
        let clientId: String
        let index: Int
        @CloudGatewayMacCLINullable var connectionUrl: String?
        let name: String
        @CloudGatewayMacCLINullable var owner: String?
        @CloudGatewayMacCLINullable var internalIp: String?
        let cloudState: CloudState
        let eligibility: Eligibility
        let installed: Bool
        let source: Source
        let selected: Bool
        @CloudGatewayMacCLINullable var tunnel: Tunnel?
        let readAt: Date
        @CloudGatewayMacCLINullable var updatedAt: Date?

        init(_ client: CloudGatewayMacControllerState.Client, index: Int, selectedId: String?,
             observation: CloudGatewayMacCLIStatus.Tunnel.Observation) {
            configId = client.identifier
            clientId = client.clientId
            self.index = index
            connectionUrl = client.connectionUrl.map(CloudGatewayMacCLIText.sanitize)
            name = CloudGatewayMacCLIText.sanitize(client.clientName)
            owner = client.ownerLabel.map(CloudGatewayMacCLIText.sanitize)
            internalIp = client.internalIp.map(CloudGatewayMacCLIText.sanitize)
            cloudState = switch client.cloudState {
            case .creating: .creating
            case .active: .active
            case .failed: .failed
            case .removed: .removed
            }
            eligibility = switch client.eligibility {
            case .eligible: .eligible
            case .inactive: .inactive
            case .configMissing: .configMissing
            case .regionUnavailable: .regionUnavailable
            }
            installed = client.isInstalled
            source = client.source == .cloud ? .cloud : .cache
            selected = client.identifier == selectedId
            tunnel = observation == .unavailable ? nil : client.status.map { status in
                switch status {
                case .invalid: .invalid
                case .disconnected: .disconnected
                case .connecting: .connecting
                case .connected: .connected
                case .reasserting: .reasserting
                case .disconnecting: .disconnecting
                }
            }
            readAt = client.readAt
            updatedAt = client.updatedAt
        }
    }

    let accountId: String
    let scope: Scope
    let freshness: Freshness
    let profileObservation: CloudGatewayMacCLIStatus.Tunnel.Observation
    @CloudGatewayMacCLINullable var profilesObservedAt: Date?
    @CloudGatewayMacCLINullable var regionId: String?
    let regions: [Region]
    let isLong: Bool

    private enum CodingKeys: String, CodingKey {
        case accountId, scope, freshness, profileObservation, profilesObservedAt, regionId, regions
    }

    init(_ state: CloudGatewayMacControllerState, accountId: String, regionId: String?, isStale: Bool = false,
         eligibleOnly: Bool = false, isLong: Bool = false) {
        self.isLong = isLong
        self.accountId = accountId
        scope = state.access == .offline ? .installed : .authorized
        freshness = isStale ? .stale : state.inventory == .cached ? .cached : .current
        let observation = CloudGatewayMacCLIStatus.Tunnel.Observation(state)
        profileObservation = observation
        profilesObservedAt = state.profilesObservedAt
        self.regionId = regionId
        regions = CloudGatewayMacCLIInventoryOrder.regions(state, accountId: accountId).compactMap { clients in
            guard let first = clients.first, regionId == nil || first.regionId == regionId else { return nil }
            let configs = clients.enumerated().compactMap { index, client -> Config? in
                guard !eligibleOnly || client.eligibility == .eligible else { return nil }
                return Config(client, index: index + 1, selectedId: state.selectedIdentifier, observation: observation)
            }
            guard !configs.isEmpty else { return nil }
            return Region(regionId: first.regionId, name: CloudGatewayMacCLIText.sanitize(first.regionName), configs: configs)
        }
    }
}

struct CloudGatewayMacCLIClientCreation: Encodable {
    let regionId: String
    let name: String
}

struct CloudGatewayMacCLIMutation: Encodable {
    enum Command: String, Encodable { case up, down, logout, update, add, remove }

    let command: Command
    let operation: CloudGatewayMacCLIOperation
    let tunnel: CloudGatewayMacCLIStatus.Tunnel
    @CloudGatewayMacCLINullable var choices: CloudGatewayMacCLIInventory?
    var update: CloudGatewayMacCLIUpdate? = nil
    var creation: CloudGatewayMacCLIClientCreation? = nil
}

struct CloudGatewayMacCLIRefresh: Encodable {
    enum Result: String, Encodable {
        case refreshed, unavailable, denied, skipped, superseded
        case signInRequired = "sign_in_required", timedOut = "timed_out"
    }

    let result: Result
    @CloudGatewayMacCLINullable var inventory: CloudGatewayMacCLIInventory?

    init(_ result: CloudGatewayMacRefreshResult, inventory: CloudGatewayMacCLIInventory?) {
        self.result = switch result {
        case .refreshed: .refreshed
        case .unavailable: .unavailable
        case .denied: .denied
        case .signInRequired: .signInRequired
        case .skipped: .skipped
        case .superseded: .superseded
        case .timedOut: .timedOut
        }
        self.inventory = inventory
    }
}

extension CloudGatewayMacControllerState {
    var isPendingRestoration: Bool {
        isRestoringSession || isAuthSettling || access == .checking
    }
}
