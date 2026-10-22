import CryptoKit
import Foundation

@MainActor
public final class CloudGatewayMacControllerRequests {
    private struct Receipt: Codable {
        let digest: String
        var operation: CloudGatewayMacControllerOperation? = nil
        let expires: Date
        // Older controllers persisted only admission, so their outcome is unknown
        let accepted: Bool?

        enum CodingKeys: String, CodingKey { case digest, expires, accepted }
    }

    private struct Storage: Codable {
        var receipts: [UUID: Receipt]
        var latest: CloudGatewayMacControllerOperation? = nil

        enum CodingKeys: String, CodingKey { case receipts }
    }

    private var storage: Storage
    private var stop: (digest: String, operation: CloudGatewayMacControllerOperation)?
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
        for id in storage.receipts.keys {
            if storage.receipts[id]?.operation == nil || storage.receipts[id]?.operation?.state == .accepted
                || storage.receipts[id]?.operation?.state == .running {
                storage.receipts[id]?.operation = .init(id: id, state: .unknown)
            }
        }
        if let latest = storage.latest, latest.state == .accepted || latest.state == .running {
            storage.latest = .init(id: latest.id, state: .unknown)
        }
    }

    public var latest: CloudGatewayMacControllerOperation? { stop?.operation ?? storage.latest }

    public func lookup(_ request: CloudGatewayMacControllerRequest) throws -> CloudGatewayMacControllerOperation? {
        let digest = Self.digest(request)
        if request.action == .turnOff {
            guard let stop, stop.operation.id == request.id else { return nil }
            guard stop.digest == digest else { throw CloudGatewayMacControllerFailure.invalidRequest }
            return stop.operation.state == .failed || stop.operation.state == .unknown ? nil : stop.operation
        }
        guard let receipt = storage.receipts[request.id], receipt.expires > now() else { return nil }
        guard receipt.digest == digest else { throw CloudGatewayMacControllerFailure.invalidRequest }
        return receipt.operation ?? .init(id: request.id, state: .unknown)
    }

    public func operation(id: UUID) -> CloudGatewayMacControllerOperation {
        if let stop, stop.operation.id == id { return stop.operation }
        guard let receipt = storage.receipts[id], receipt.expires > now() else {
            return .init(id: id, state: .unknown)
        }
        return receipt.operation ?? .init(id: id, state: .unknown)
    }

    public func accept(_ request: CloudGatewayMacControllerRequest) throws -> CloudGatewayMacControllerOperation {
        let operation = CloudGatewayMacControllerOperation(id: request.id, state: .accepted)
        if request.action == .turnOff {
            stop = (Self.digest(request), operation)
            return operation
        }
        var next = storage
        next.receipts = next.receipts.filter { $0.value.expires > now() }
        guard next.receipts.count < 64 else { throw CloudGatewayMacControllerFailure.unavailable }
        next.receipts[request.id] = Receipt(digest: Self.digest(request), operation: operation,
                                           expires: now().addingTimeInterval(600), accepted: true)
        next.latest = operation
        try persist(JSONEncoder().encode(next))
        storage = next
        stop = nil
        return operation
    }

    @discardableResult
    public func finish(id: UUID, state: CloudGatewayMacControllerOperation.State,
                       failure: CloudGatewayMacControllerFailure? = nil) -> CloudGatewayMacControllerOperation {
        let operation = CloudGatewayMacControllerOperation(id: id, state: state, failure: failure)
        if stop?.operation.id == id {
            stop?.operation = operation
            return operation
        }
        guard storage.receipts[id] != nil else { return .init(id: id, state: .unknown) }
        storage.receipts[id]?.operation = operation
        storage.latest = operation
        do { try persist(JSONEncoder().encode(storage)) }
        catch {
            // Work already ran, so failed persistence must never trigger replay
            let unknown = CloudGatewayMacControllerOperation(id: id, state: .unknown)
            storage.receipts[id]?.operation = unknown
            storage.latest = unknown
            return unknown
        }
        return operation
    }

    private static func digest(_ request: CloudGatewayMacControllerRequest) -> String {
        let content = [request.action.rawValue, request.identifier ?? "", request.regionId ?? "",
                       request.clientName ?? "", request.contextId?.uuidString ?? ""]
        return SHA256.hash(data: (try? JSONEncoder().encode(content)) ?? Data())
            .map { String(format: "%02x", $0) }.joined()
    }
}
