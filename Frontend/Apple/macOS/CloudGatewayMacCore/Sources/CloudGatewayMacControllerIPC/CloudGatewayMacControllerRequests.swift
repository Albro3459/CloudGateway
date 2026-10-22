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

    private var storage: Storage
    private var stop: (id: UUID, digest: String)?
    private var result: CloudGatewayMacControllerOperation?
    private var outcome: CloudGatewayMacCommandOutcome?
    private var owner: CloudGatewayMacSessionToken?
    private var isAccountBound = false
    private var resultExpires = Date.distantPast
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
        guard let result else { return nil }
        return result.state == .accepted || result.state == .running || resultExpires > now() ? result : nil
    }

    public func lookup(_ request: CloudGatewayMacControllerRequest) throws -> CloudGatewayMacControllerOperation? {
        let digest = Self.digest(request)
        if request.action == .turnOff {
            guard let stop, stop.id == request.id, let result = latest else { return nil }
            guard stop.digest == digest else { throw CloudGatewayMacControllerFailure.invalidRequest }
            return result.state == .failed || result.state == .unknown ? nil : result
        }
        guard let receipt = storage.receipts[request.id],
              receipt.expires > now() || latest?.id == request.id else { return nil }
        guard receipt.digest == digest else { throw CloudGatewayMacControllerFailure.invalidRequest }
        return operation(id: request.id)
    }

    public func operation(id: UUID) -> CloudGatewayMacControllerOperation {
        guard let latest, latest.id == id else { return .init(id: id, state: .unknown) }
        return latest
    }

    // Only connect and creation outcomes describe account data, so only they are hidden after logout or account change
    public func outcome(id: UUID, session: CloudGatewayMacSessionToken?) -> CloudGatewayMacCommandOutcome? {
        guard latest?.id == id else { return nil }
        return !isAccountBound || owner == session ? outcome : nil
    }

    public func accept(_ request: CloudGatewayMacControllerRequest) throws -> CloudGatewayMacControllerOperation {
        let operation = CloudGatewayMacControllerOperation(id: request.id, state: .accepted)
        let expires = now().addingTimeInterval(600)
        if request.action == .turnOff {
            stop = (request.id, Self.digest(request))
        } else {
            var next = storage
            next.receipts = next.receipts.filter { $0.value.expires > now() }
            guard next.receipts.count < 64 else { throw CloudGatewayMacControllerFailure.unavailable }
            next.receipts[request.id] = Receipt(digest: Self.digest(request), expires: expires)
            try persist(JSONEncoder().encode(next))
            storage = next
            stop = nil
        }
        result = operation
        outcome = nil
        owner = nil
        isAccountBound = request.action.hasAccountBoundOutcome
        resultExpires = expires
        return operation
    }

    @discardableResult
    public func finish(id: UUID, state: CloudGatewayMacControllerOperation.State,
                       failure: CloudGatewayMacControllerFailure? = nil, outcome: CloudGatewayMacCommandOutcome? = nil,
                       session: CloudGatewayMacSessionToken? = nil) -> CloudGatewayMacControllerOperation {
        guard result?.id == id else { return .init(id: id, state: .unknown) }
        let operation = CloudGatewayMacControllerOperation(id: id, state: state, failure: failure)
        // Admission already prevents replay, results stay in memory only
        result = operation
        self.outcome = outcome
        owner = session
        if state != .accepted && state != .running { resultExpires = now().addingTimeInterval(600) }
        return operation
    }

    private static func digest(_ request: CloudGatewayMacControllerRequest) -> String {
        let content = [request.action.rawValue, request.identifier ?? "", request.regionId ?? "",
                       request.clientName ?? "", request.contextId?.uuidString ?? ""]
        return SHA256.hash(data: (try? JSONEncoder().encode(content)) ?? Data())
            .map { String(format: "%02x", $0) }.joined()
    }
}
