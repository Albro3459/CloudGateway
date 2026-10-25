import CloudGatewayMacControllerIPC
import Foundation

enum CloudGatewayMacCLISelector: Equatable {
    case client(UUID)
    case region(String, index: Int)
}

enum CloudGatewayMacCLIInventoryOrder {
    static func regions(_ state: CloudGatewayMacControllerState, accountId: String) -> [[CloudGatewayMacControllerState.Client]] {
        let clients = state.clients.filter { $0.identifier.hasPrefix(accountId + "/") }
        return Dictionary(grouping: clients, by: \.regionId).values.map { clients in
            clients.sorted { lhs, rhs in
                if (lhs.ownerLabel ?? "") != (rhs.ownerLabel ?? "") { return (lhs.ownerLabel ?? "") < (rhs.ownerLabel ?? "") }
                if lhs.clientName != rhs.clientName { return lhs.clientName < rhs.clientName }
                return lhs.identifier < rhs.identifier
            }
        }.sorted { lhs, rhs in
            let left = lhs[0]
            let right = rhs[0]
            if left.regionOrder != right.regionOrder { return left.regionOrder < right.regionOrder }
            if left.regionName != right.regionName { return left.regionName < right.regionName }
            return left.regionId < right.regionId
        }
    }

    static func region(_ value: String, in regions: [[CloudGatewayMacControllerState.Client]]) throws -> String {
        try region(value, in: regions.compactMap(\.first).map { (id: $0.regionId, name: $0.regionName) },
                   scope: "this account's current inventory")
    }

    static func region(_ value: String, in rows: [(id: String, name: String)], scope: String) throws -> String {
        if let exact = rows.first(where: { $0.id == value }) { return exact.id }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matches = rows.filter { row in
            let components = row.id.split(separator: "-")
            let city = components.count >= 3 ? components.dropFirst().dropLast().joined(separator: "-") : ""
            return row.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized
                || (!city.isEmpty && city.lowercased() == normalized)
        }
        if matches.count == 1 { return matches[0].id }
        let candidates = (matches.isEmpty ? rows : matches).map {
            "\(CloudGatewayMacCLIText.sanitize($0.id)) (\(CloudGatewayMacCLIText.sanitize($0.name)))"
        }.joined(separator: ", ")
        let message = matches.isEmpty
            ? "Region '\(CloudGatewayMacCLIText.sanitize(value))' is unavailable in \(scope)"
            : "Region '\(CloudGatewayMacCLIText.sanitize(value))' is ambiguous. Use a full region ID"
        throw CloudGatewayMacCLIError(.usage, message: message,
                                      suggestion: "Available regions: \(candidates.isEmpty ? "none" : candidates)")
    }

    static func resolve(_ selector: CloudGatewayMacCLISelector, state: CloudGatewayMacControllerState,
                        accountId: String) throws -> String {
        let orderedRegions = regions(state, accountId: accountId)
        switch selector {
        case .client(let uuid):
            let matches = orderedRegions.flatMap { $0 }.filter { UUID(uuidString: $0.clientId) == uuid }
            guard matches.count == 1 else {
                throw CloudGatewayMacCLIError(.configUnavailable, message: matches.isEmpty
                    ? "Client UUID '\(uuid.uuidString.lowercased())' is unavailable in this account's current inventory"
                    : "Client UUID '\(uuid.uuidString.lowercased())' is ambiguous. Use a region and index from `cloudgateway ls`")
            }
            return matches[0].identifier
        case .region(let value, let index):
            let regionId = try region(value, in: orderedRegions)
            let clients = orderedRegions.first { $0.first?.regionId == regionId } ?? []
            guard index > 0, index <= clients.count else {
                throw CloudGatewayMacCLIError(.usage, message: "Index \(index) is out of range for \(regionId)",
                                              suggestion: "Use an index from 1 to \(clients.count). Run: cloudgateway ls")
            }
            return clients[index - 1].identifier
        }
    }
}
