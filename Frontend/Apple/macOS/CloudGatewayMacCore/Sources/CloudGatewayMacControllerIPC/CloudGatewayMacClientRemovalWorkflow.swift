import CloudGatewayMacCore
import Foundation

extension CloudGatewayMacFrontendClient {
    public func removeClient(identifier: String, accountId: String, id: UUID = UUID(),
                             timeout: Duration = .seconds(30)) async throws -> CloudGatewayMacCommandOutcome {
        guard presentation.accountId == accountId else { throw CloudGatewayMacControllerFailure.rejected }
        let reply: CloudGatewayMacControllerReply
        do {
            reply = try await userRequest(.removeClient, id: id, identifier: identifier)
        } catch CloudGatewayMacControllerFailure.outcomeUnknown {
            return try await resolveRemoval(id, timeout: timeout)
        }
        guard reply.operation?.id == id else { return .unknown }
        if reply.operation?.state == .accepted || reply.operation?.state == .running {
            return try await resolveRemoval(id, timeout: timeout)
        }
        return removalOutcome(from: reply, id: id)
    }

    private func resolveRemoval(_ id: UUID, timeout: Duration) async throws -> CloudGatewayMacCommandOutcome {
        do {
            return removalOutcome(from: try await awaitOutcome(of: id, timeout: timeout), id: id)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .unknown
        }
    }

    private func removalOutcome(from reply: CloudGatewayMacControllerReply, id: UUID) -> CloudGatewayMacCommandOutcome {
        guard let operation = reply.operation, operation.id == id else { return .unknown }
        switch (operation.state, reply.outcome) {
        case (.completed, .completed(let warning)): return .completed(warning: warning)
        case (.failed, .failed(let failure)): return .failed(failure)
        default: return .unknown
        }
    }

    public func message(forRemoval outcome: CloudGatewayMacCommandOutcome) -> String {
        switch outcome {
        case .completed(warning: .localCleanupIncomplete):
            return "Client was removed, but its local VPN profile could not be cleaned up. Choose Refresh"
        case .completed(warning: .some(_)):
            return "Client was removed, but the client list could not refresh. Choose Refresh"
        case .completed(warning: nil): return "Client was removed"
        case .failed(.clientActive): return "Disconnect this config and wait for it to stop before deleting it"
        case .failed(.accessDenied): return "Account access was denied. Sign in again after access is restored"
        case .failed(.signInRequired): return "Your session changed. Sign in and select the client again"
        case .failed(.networkUnavailable): return "Unable to reach CloudGateway. Choose Refresh before trying again"
        case .failed(.busy): return "Another operation is in progress. Wait for it to finish and try again"
        case .failed(.selectionUnavailable), .failed(.configUnavailable):
            return "The client list changed. Choose Refresh and select the client again"
        case .failed: return "Client could not be removed. Refresh before trying again"
        default: return "Could not confirm whether the client was removed. Refresh the client list before trying again"
        }
    }
}
