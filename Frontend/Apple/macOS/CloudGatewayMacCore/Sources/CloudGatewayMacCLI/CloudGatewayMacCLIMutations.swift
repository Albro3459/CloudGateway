import CloudGatewayKit
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

    func add(region: String, name: String, accepted: (UUID) throws -> Void) async throws -> CloudGatewayMacCLIData {
        try await requireCurrentBuild()
        let (reply, settled) = try await poll(.snapshot, until: deadline) {
            let state = try Self.state(of: $0)
            return state.isPendingRestoration || state.isAwaitingVerification || state.inventory == .refreshing
        }
        guard settled else { throw CloudGatewayMacCLIError(.timeout) }
        let state = try Self.state(of: reply)
        guard state.accountId != nil else {
            if state.access == .denied { throw CloudGatewayMacCLIError(.accessDenied) }
            if state.hasRetainedSession, state.access == .unreachable { throw CloudGatewayMacCLIError(.networkUnavailable) }
            throw CloudGatewayMacCLIError(.signInRequired)
        }
        guard state.creationAllowed else { throw CloudGatewayMacCLIError(.busy) }
        let prepared: CloudGatewayMacControllerReply
        do { prepared = try await call { [client] in try await client.send(.prepareClient) } }
        catch CloudGatewayMacControllerFailure.unavailable {
            let current = try? await call { [client] in try await client.send(.snapshot) }
            try Task.checkCancellation()
            if let state = current?.state, state.accountId == nil {
                if state.access == .denied { throw CloudGatewayMacCLIError(.accessDenied) }
                if !state.hasRetainedSession || state.access != .unreachable { throw CloudGatewayMacCLIError(.signInRequired) }
            }
            throw CloudGatewayMacCLIError(.networkUnavailable, message: "Unable to load regions for client creation. Try again")
        }
        guard let context = prepared.creation else { throw CloudGatewayMacCLIError(.invalidResponse) }
        let regions = context.regions.filter(\.enabled)
        let regionId = try CloudGatewayMacCLIInventoryOrder.region(region, in: regions.map { (id: $0.regionId, name: $0.displayName) },
                                                                  scope: "the enabled creation regions")
        guard let selected = regions.first(where: { $0.regionId == regionId }), selected.capacity?.isKnown == true else {
            throw CloudGatewayMacCLIError(.networkUnavailable, message: "Unable to check capacity for \(regionId). Try again")
        }
        guard selected.capacity?.isAtCapacity == false else {
            throw CloudGatewayMacCLIError(.configUnavailable, message: "Region \(regionId) has no available client capacity")
        }
        return try await submit(.createClient, creation: .init(regionId: regionId, name: name), contextId: context.id, accepted: accepted)
    }

    func mutate(_ action: CloudGatewayMacControllerRequest.Action, selector: CloudGatewayMacCLISelector? = nil,
                mode: CloudGatewayRoutingMode? = nil,
                accepted: (UUID) throws -> Void) async throws -> CloudGatewayMacCLIData {
        if action == .turnOff { _ = try await call { [client] in try await client.handshake() } }
        else { try await requireCurrentBuild() }
        var identifier: String?
        if action == .connect || action == .disconnectClient || action == .removeClient || action == .setMode {
            let (reply, settled) = try await poll(.snapshot, until: deadline) {
                let state = try Self.state(of: $0)
                let target = state.selectedIdentifier
                let unresolved = state.accountId != nil && state.inventory == .refreshing
                    && !state.clients.contains { $0.identifier == target }
                return state.isPendingRestoration || state.isAwaitingVerification
                    || (action == .connect && state.setup == .checkingConnection)
                    || (selector != nil || action == .setMode ? state.inventory == .refreshing : unresolved)
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
        return try await submit(action, identifier: identifier, mode: mode, accepted: accepted)
    }

    private func submit(_ action: CloudGatewayMacControllerRequest.Action, identifier: String? = nil,
                        mode: CloudGatewayRoutingMode? = nil,
                        creation: CloudGatewayMacCLIClientCreation? = nil, contextId: UUID? = nil,
                        accepted: (UUID) throws -> Void) async throws -> CloudGatewayMacCLIData {
        let id = UUID()
        func observationFailure(_ error: any Error) -> CloudGatewayMacCLIError {
            var failure = CloudGatewayMacCLIError(error)
            if failure.operationId != nil && !(action == .removeClient && failure.code == .operationUnknown) { return failure }
            let recovery = action == .removeClient
                ? ". If the result is still unknown, refresh online inventory with cloudgateway refresh, then run cloudgateway ls and inspect the original client UUID before another manual removal attempt"
                : ""
            failure = .init(failure.code, message: failure.message,
                            suggestion: "Check this operation before retrying: cloudgateway status --operation \(id.uuidString.lowercased())" + recovery,
                            data: failure.data)
            failure.operationId = id
            return failure
        }
        let reservation: CloudGatewayMacControllerReply
        do {
            reservation = try await call { [client] in
                try await client.send(action, id: id, identifier: identifier, regionId: creation?.regionId,
                                      clientName: creation?.name, contextId: contextId, mode: mode)
            }
        } catch {
            if action == .removeClient { throw observationFailure(error) }
            throw error
        }
        guard reservation.operation?.id == id, reservation.operation?.state == .accepted else {
            let failure = CloudGatewayMacCLIError(.invalidResponse)
            throw action == .removeClient ? observationFailure(failure) : failure
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
            if action != .removeClient, operation.failure?.code == .selectionUnavailable {
                // Use a new account-filtered snapshot, never the reservation's old account view
                if let current = try? await call({ [client] in try await client.send(.snapshot) }),
                   let state = current.state, let accountId = state.accountId {
                    choices = .init(state, accountId: accountId, regionId: nil, eligibleOnly: true)
                }
            }
            let command: CloudGatewayMacCLIMutation.Command = switch action {
            case .connect: .up
            case .turnOff, .disconnectClient: .down
            case .createClient: .add
            case .removeClient: .remove
            case .setMode: .mode
            default: .logout
            }
            let data = CloudGatewayMacCLIData.mutation(.init(command: command, operation: operation, tunnel: tunnel, choices: choices,
                                                            update: reply.update.map(CloudGatewayMacCLIUpdate.init), creation: creation,
                                                            requestedMode: mode,
                                                            mode: action == .setMode ? reply.state.map(CloudGatewayMacCLIModeStatus.init) : nil))
            if var failure = operation.failure {
                failure.data = data
                failure.operationId = id
                throw failure
            }
            guard operation.state == .completed else { throw CloudGatewayMacCLIError(.invalidResponse) }
            return data
        } catch {
            throw observationFailure(error)
        }
    }
}
