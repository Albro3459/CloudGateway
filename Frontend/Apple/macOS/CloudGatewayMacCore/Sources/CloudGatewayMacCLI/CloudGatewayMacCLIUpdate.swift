import CloudGatewayMacControllerIPC
import Foundation

struct CloudGatewayMacCLIUpdate: Encodable {
    enum Phase: String, Encodable {
        case prepared, stopping, activating, reconnecting, completed, failed, superseded
        case approvalRequired = "approval_required", restartRequired = "restart_required"
        case checkingReadiness = "checking_readiness"
    }

    struct Target: Encodable {
        let version: String
        let build: String
        let codeHash: String
    }

    let id: String
    let phase: Phase
    let target: Target
    @CloudGatewayMacCLINullable var configId: String?
    let reconnect: Bool
    @CloudGatewayMacCLINullable var error: CloudGatewayMacCLIRecord.Failure?
    @CloudGatewayMacCLINullable var warning: CloudGatewayMacCLIRecord.Failure?

    init(_ update: CloudGatewayMacManagedUpdateStatus) {
        id = update.id.uuidString.lowercased()
        phase = switch update.phase {
        case .prepared: .prepared
        case .stopping: .stopping
        case .activating: .activating
        case .approvalRequired: .approvalRequired
        case .restartRequired: .restartRequired
        case .checkingReadiness: .checkingReadiness
        case .reconnecting: .reconnecting
        case .completed: .completed
        case .failed: .failed
        case .superseded: .superseded
        }
        target = .init(version: CloudGatewayMacCLIText.sanitize(update.target.version),
                       build: CloudGatewayMacCLIText.sanitize(update.target.build), codeHash: update.target.codeHash)
        configId = update.identifier
        reconnect = update.reconnect
        error = update.error.map { .init(CloudGatewayMacCLIError(updateFailure: $0)) }
        warning = update.warning.map {
            let failure = $0 == .storageUnavailable
                ? CloudGatewayMacCLIError(.storageUnavailable, message: "CloudGateway could not persist the update safely. "
                    + "Reconnect suppression cannot be guaranteed after controller restart")
                : CloudGatewayMacCLIError(updateFailure: $0)
            return .init(failure)
        }
    }
}

extension CloudGatewayMacCLISession {
    func update(allowDisconnect: Bool, accepted: (UUID) throws -> Void) async throws -> CloudGatewayMacCLIData {
        try await requireCurrentBuild()
        let id = UUID()
        var reply = try await call { [client] in
            try await client.send(.update, id: id, allowDisconnect: allowDisconnect)
        }
        if reply.update?.error == .busy, let state = reply.state, state.isPendingUpdateStartup {
            let (_, settled) = try await poll(.snapshot, until: deadline) { try Self.state(of: $0).isPendingUpdateStartup }
            guard settled else { throw CloudGatewayMacCLIError(.timeout, message: "CloudGateway is still restoring update prerequisites") }
            reply = try await call { [client] in
                try await client.send(.update, id: id, allowDisconnect: allowDisconnect)
            }
        }
        guard reply.operation?.id == id, reply.update?.id == id else {
            throw CloudGatewayMacCLIError(.invalidResponse)
        }
        if reply.operation?.state != .accepted {
            return try updateResult(reply, id: id)
        }
        guard reply.update?.phase == .prepared else { throw CloudGatewayMacCLIError(.invalidResponse) }
        // Output must succeed before confirmation can authorize any effects
        try accepted(id)
        do {
            reply = try await call { [client] in try await client.confirm(id) }
            while true {
                guard reply.operation?.id == id else { throw CloudGatewayMacCLIError(.invalidResponse) }
                if let update = reply.update {
                    guard update.id == id else { throw CloudGatewayMacCLIError(.invalidResponse) }
                    if update.phase == .approvalRequired || update.phase == .restartRequired { break }
                }
                guard reply.operation?.state == .accepted || reply.operation?.state == .running else { break }
                try await call { [clock] in try await clock.sleep(Self.pollInterval) }
                reply = try await call { [client] in try await client.send(.operation, contextId: id) }
            }
            return try updateResult(reply, id: id)
        } catch {
            throw Self.updateObservationFailure(error, id: id)
        }
    }

    private func updateResult(_ reply: CloudGatewayMacControllerReply, id: UUID) throws -> CloudGatewayMacCLIData {
        guard reply.operation?.id == id, let operation = Self.operation(of: reply) else {
            throw CloudGatewayMacCLIError(.invalidResponse)
        }
        let tunnel: CloudGatewayMacCLIStatus.Tunnel = if client.isCurrentBuild, let state = reply.state { .init(state) }
            else { .init(try Self.status(of: reply)) }
        let update = client.isCurrentBuild ? reply.update : nil
        let data = CloudGatewayMacCLIData.mutation(.init(command: .update, operation: operation, tunnel: tunnel,
                                                        update: update.map(CloudGatewayMacCLIUpdate.init)))
        if let failure = Self.updateFailure(update) ?? operation.failure {
            var failure = Self.updateObservationFailure(failure, id: id)
            failure.data = data
            throw failure
        }
        guard operation.state == .completed else { throw CloudGatewayMacCLIError(.invalidResponse) }
        return data
    }

    static func updateFailure(_ update: CloudGatewayMacManagedUpdateStatus?) -> CloudGatewayMacCLIError? {
        guard let update else { return nil }
        if update.phase == .approvalRequired { return .init(.approvalRequired) }
        if update.phase == .restartRequired { return .init(.restartRequired) }
        if let error = update.error { return .init(updateFailure: error) }
        if update.phase == .superseded { return .init(.updateSuperseded) }
        return nil
    }

    static func updateObservationFailure(_ error: any Error, id: UUID) -> CloudGatewayMacCLIError {
        let original = CloudGatewayMacCLIError(error)
        if original.operationId != nil { return original }
        let lookup = "cloudgateway status --operation \(id.uuidString.lowercased())"
        let guidance = "Check this operation before retrying: \(lookup)"
        let suggestion: String
        switch original.code {
        case .timeout, .interrupted, .operationUnknown, .controllerUnavailable, .controllerRejected, .invalidResponse:
            suggestion = "Observation stopped. Confirmed update work can keep running. \(guidance)"
        default:
            suggestion = original.suggestion.map { "\($0). \(guidance)" } ?? guidance
        }
        var failure = CloudGatewayMacCLIError(original.code, message: original.message,
                                              suggestion: suggestion, data: original.data)
        failure.operationId = id
        return failure
    }
}

private extension CloudGatewayMacControllerState {
    var isPendingUpdateStartup: Bool {
        isPendingRestoration || isAwaitingVerification || inventory == .refreshing || !observationAvailable
    }
}
