import CloudGatewayMacControllerIPC
import CloudGatewayMacCore
import Foundation

extension CloudGatewayMacCLISession {
    func refresh(regionId: String?, isList: Bool, isLong: Bool = false) async throws -> CloudGatewayMacCLIData {
        try await requireCurrentBuild()
        while true {
            let reply = try await call { [client] in try await client.send(.awaitRefresh) }
            guard let result = reply.refresh else { throw CloudGatewayMacCLIError(.invalidResponse) }
            if result == .timedOut, clock.now() + Self.pollInterval < deadline {
                try await call { [clock] in try await clock.sleep(Self.pollInterval) }
                continue
            }
            let state = try Self.state(of: reply)
            let canResolveRegion: Bool = switch result {
            case .refreshed: true
            case .denied, .signInRequired: false
            default:
                state.accessAuthorized && (state.access == .online || state.access == .offline)
                    && !state.isPendingRestoration && !state.isAwaitingVerification
                    && (state.inventory == .current || state.inventory == .cached)
            }
            let inventory = try state.accountId.flatMap { accountId -> CloudGatewayMacCLIInventory? in
                guard regionId == nil || canResolveRegion else { return nil }
                let regionId = try regionId.map {
                    try CloudGatewayMacCLIInventoryOrder.region($0, in: CloudGatewayMacCLIInventoryOrder.regions(state, accountId: accountId))
                }
                return CloudGatewayMacCLIInventory(state, accountId: accountId, regionId: regionId,
                                                    isStale: result != .refreshed, isLong: isLong)
            }
            let data: CloudGatewayMacCLIData = if isList, let inventory { .inventory(inventory) }
                else { .refresh(.init(result, inventory: inventory)) }
            switch result {
            case .refreshed:
                guard inventory != nil else { throw CloudGatewayMacCLIError(.invalidResponse) }
                return data
            case .timedOut:
                throw CloudGatewayMacCLIError(.timeout, data: data)
            case .unavailable: throw CloudGatewayMacCLIError(.networkUnavailable, data: data)
            case .denied: throw CloudGatewayMacCLIError(.accessDenied, data: data)
            case .signInRequired: throw CloudGatewayMacCLIError(.signInRequired, data: data)
            case .skipped: throw CloudGatewayMacCLIError(.refreshSkipped, data: data)
            case .superseded: throw CloudGatewayMacCLIError(.refreshSuperseded, data: data)
            }
        }
    }

    func mutate(_ action: CloudGatewayMacControllerRequest.Action, selector: CloudGatewayMacCLISelector? = nil,
                accepted: (UUID) throws -> Void) async throws -> CloudGatewayMacCLIData {
        if action == .turnOff { _ = try await call { [client] in try await client.handshake() } }
        else { try await requireCurrentBuild() }
        var identifier: String?
        if action == .connect || action == .disconnectClient {
            let (reply, settled) = try await poll(.snapshot, until: deadline) {
                let state = try Self.state(of: $0)
                let target = state.selectedIdentifier
                let unresolved = state.accountId != nil && state.inventory == .refreshing
                    && !state.clients.contains { $0.identifier == target }
                return state.isPendingRestoration || state.isAwaitingVerification
                    || (action == .connect && state.setup == .checkingConnection)
                    || (selector != nil ? state.inventory == .refreshing : unresolved)
            }
            guard settled else { throw CloudGatewayMacCLIError(.timeout) }
            let state = try Self.state(of: reply)
            guard let accountId = state.accountId else {
                if state.access == .denied { throw CloudGatewayMacCLIError(.accessDenied) }
                if state.hasRetainedSession, state.access == .unreachable { throw CloudGatewayMacCLIError(.networkUnavailable) }
                throw CloudGatewayMacCLIError(.signInRequired)
            }
            if let selector {
                guard state.inventory != .unavailable else { throw CloudGatewayMacCLIError(.networkUnavailable) }
                identifier = try CloudGatewayMacCLIInventoryOrder.resolve(selector, state: state, accountId: accountId)
            }
        }
        let id = UUID()
        let targetIdentifier = identifier
        let reservation = try await call { [client] in try await client.send(action, id: id, identifier: targetIdentifier) }
        guard reservation.operation?.id == id, reservation.operation?.state == .accepted else {
            throw CloudGatewayMacCLIError(.invalidResponse)
        }
        // FileHandle writes are unbuffered. A failed write leaves the reservation unconfirmed
        try accepted(id)
        do {
            var reply = try await call { [client] in try await client.confirm(id) }
            while true {
                guard reply.operation?.id == id else { throw CloudGatewayMacCLIError(.invalidResponse) }
                guard reply.operation?.state == .accepted || reply.operation?.state == .running else { break }
                try await call { [clock] in try await clock.sleep(Self.pollInterval) }
                reply = try await call { [client] in try await client.send(.operation, contextId: id) }
            }
            guard reply.operation?.id == id, let operation = Self.operation(of: reply) else {
                throw CloudGatewayMacCLIError(.invalidResponse)
            }
            let tunnel: CloudGatewayMacCLIStatus.Tunnel = if client.isCurrentBuild, let state = reply.state { .init(state) }
                else { .init(try Self.status(of: reply)) }
            var choices: CloudGatewayMacCLIInventory?
            if operation.failure?.code == .selectionUnavailable {
                // Use a new account-filtered snapshot, never the reservation's old account view
                if let current = try? await call({ [client] in try await client.send(.snapshot) }),
                   let state = current.state, let accountId = state.accountId {
                    choices = .init(state, accountId: accountId, regionId: nil, eligibleOnly: true)
                }
            }
            let command: CloudGatewayMacCLIMutation.Command = action == .connect ? .up : (action == .turnOff || action == .disconnectClient) ? .down : .logout
            let data = CloudGatewayMacCLIData.mutation(.init(command: command, operation: operation, tunnel: tunnel, choices: choices,
                                                            update: reply.update.map(CloudGatewayMacCLIUpdate.init)))
            if var failure = operation.failure {
                failure.data = data
                failure.operationId = id
                throw failure
            }
            guard operation.state == .completed else { throw CloudGatewayMacCLIError(.invalidResponse) }
            return data
        } catch {
            var failure = CloudGatewayMacCLIError(error)
            if failure.operationId != nil { throw failure }
            failure = .init(failure.code, message: failure.message,
                            suggestion: "Check this operation before retrying: cloudgateway status --operation \(id.uuidString.lowercased())",
                            data: failure.data)
            failure.operationId = id
            throw failure
        }
    }
}
