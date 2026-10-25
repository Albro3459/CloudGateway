import CloudGatewayMacCore
import CryptoKit
import Foundation

@MainActor
public final class CloudGatewayMacControllerRequests {
    private struct Receipt: Codable {
        let digest: String
        let expires: Date
    }

    private struct Storage: Codable {
        var receipts: [UUID: Receipt]
    }

    private struct Record {
        var operation: CloudGatewayMacControllerOperation
        let digest: String
        let isStop: Bool
        let isAccountBound: Bool
        var outcome: CloudGatewayMacCommandOutcome?
        var owner: CloudGatewayMacSessionToken?
        var expires: Date

        func isLive(at now: Date) -> Bool {
            operation.state == .accepted || operation.state == .running || expires > now
        }
    }

    private var storage: Storage
    private var creation: Record?
    private var command: Record?
    private var latestId: UUID?
    private let now: () -> Date
    private let persist: (Data) throws -> Void

    public init(data: Data?, now: @escaping () -> Date = Date.init,
                persist: @escaping (Data) throws -> Void) throws {
        self.now = now
        self.persist = persist
        storage = try data.map { try JSONDecoder().decode(Storage.self, from: $0) }
            ?? Storage(receipts: [:])
        guard storage.receipts.count <= 64 else { throw CloudGatewayMacControllerFailure.invalidRequest }
        storage.receipts = storage.receipts.filter { $0.value.expires > now() }
    }

    public var latest: CloudGatewayMacControllerOperation? {
        let live = [creation, command].compactMap { $0 }.filter { $0.isLive(at: now()) }
        return (live.first { $0.operation.id == latestId } ?? live.first)?.operation
    }

    private func record(id: UUID) -> Record? {
        [creation, command].compactMap { $0 }.first { $0.operation.id == id && $0.isLive(at: now()) }
    }

    public func lookup(_ request: CloudGatewayMacControllerRequest) throws -> CloudGatewayMacControllerOperation? {
        let digest = Self.digest(request)
        if let record = record(id: request.id) {
            guard record.digest == digest else { throw CloudGatewayMacControllerFailure.invalidRequest }
            if record.isStop, record.operation.state == .failed || record.operation.state == .unknown { return nil }
            return record.operation
        }
        guard let receipt = storage.receipts[request.id], receipt.expires > now() else { return nil }
        guard receipt.digest == digest else { throw CloudGatewayMacControllerFailure.invalidRequest }
        return operation(id: request.id)
    }

    public func operation(id: UUID) -> CloudGatewayMacControllerOperation {
        record(id: id)?.operation ?? .init(id: id, state: .unknown)
    }

    // Account-bound outcomes are hidden after logout or account change
    public func outcome(id: UUID, session: CloudGatewayMacSessionToken?) -> CloudGatewayMacCommandOutcome? {
        guard let record = record(id: id) else { return nil }
        return !record.isAccountBound || record.owner == session ? record.outcome : nil
    }

    public func accept(_ request: CloudGatewayMacControllerRequest) throws -> CloudGatewayMacControllerOperation {
        if let existing = try lookup(request) { return existing }
        let operation = CloudGatewayMacControllerOperation(id: request.id, state: .accepted)
        let expires = now().addingTimeInterval(600)
        let isStop = request.action == .turnOff || request.action == .disconnectClient
        if !isStop {
            var next = storage
            next.receipts = next.receipts.filter { $0.value.expires > now() }
            guard next.receipts.count < 64 else { throw CloudGatewayMacControllerFailure.unavailable }
            next.receipts[request.id] = Receipt(digest: Self.digest(request), expires: expires)
            try persist(JSONEncoder().encode(next))
            storage = next
        }
        let record = Record(operation: operation, digest: Self.digest(request), isStop: isStop,
                            isAccountBound: request.action.hasAccountBoundOutcome, expires: expires)
        if request.action == .createClient { creation = record }
        else { command = record }
        latestId = request.id
        return operation
    }

    @discardableResult
    public func finish(id: UUID, state: CloudGatewayMacControllerOperation.State,
                       failure: CloudGatewayMacControllerFailure? = nil, warning: CloudGatewayMacCommandWarning? = nil,
                       outcome: CloudGatewayMacCommandOutcome? = nil,
                       session: CloudGatewayMacSessionToken? = nil) -> CloudGatewayMacControllerOperation {
        guard var record = record(id: id) else { return .init(id: id, state: .unknown) }
        let operation = CloudGatewayMacControllerOperation(id: id, state: state, failure: failure, warning: warning)
        // Admission already prevents replay, results stay in memory only
        record.operation = operation
        record.outcome = outcome
        record.owner = session
        if state != .accepted && state != .running { record.expires = now().addingTimeInterval(600) }
        if creation?.operation.id == id { creation = record }
        else { command = record }
        return operation
    }

    private static func digest(_ request: CloudGatewayMacControllerRequest) -> String {
        var content = [request.action.rawValue, request.identifier ?? "", request.regionId ?? "",
                       request.clientName ?? "", request.contextId?.uuidString ?? ""]
        if let mode = request.mode { content.append(mode.rawValue) }
        return SHA256.hash(data: (try? JSONEncoder().encode(content)) ?? Data())
            .map { String(format: "%02x", $0) }.joined()
    }
}
