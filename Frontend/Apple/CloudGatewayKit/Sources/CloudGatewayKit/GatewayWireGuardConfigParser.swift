import Foundation
import Network

public struct GatewayParsedWireGuardConfig: Equatable, Sendable {
    public let name: String?
    public let interface: GatewayParsedWireGuardInterface
    public let peers: [GatewayParsedWireGuardPeer]
}

public struct GatewayParsedWireGuardInterface: Equatable, Sendable {
    public let privateKey: String
    public var listenPort: UInt16?
    public var addresses = [String]()
    public var dns = [String]()
    public var dnsSearch = [String]()
    public var mtu: UInt16?
}

public struct GatewayParsedWireGuardPeer: Equatable, Sendable {
    public let publicKey: String
    public var preSharedKey: String?
    public var allowedIPs = [String]()
    public var endpoint: String?
    public var persistentKeepAlive: UInt16?
}

public enum GatewayWireGuardConfigParser {
    public enum ParseError: Error, Equatable, Sendable {
        case invalidLine(String)
        case noInterface
        case multipleInterfaces
        case interfaceHasNoPrivateKey
        case interfaceHasInvalidPrivateKey(String)
        case interfaceHasInvalidListenPort(String)
        case interfaceHasInvalidAddress(String)
        case interfaceHasInvalidDNS(String)
        case interfaceHasInvalidMTU(String)
        case peerHasNoPublicKey
        case peerHasInvalidPublicKey(String)
        case peerHasInvalidPreSharedKey(String)
        case peerHasInvalidAllowedIP(String)
        case peerHasInvalidEndpoint(String)
        case peerHasInvalidPersistentKeepAlive(String)
        case multiplePeersWithSamePublicKey
        case unrecognizedInterfaceKey(String)
        case unrecognizedPeerKey(String)
        case multipleEntriesForKey(String)
    }

    private enum Section {
        case none
        case interface
        case peer
    }

    public static func parse(_ config: String, named name: String? = nil) throws -> GatewayParsedWireGuardConfig {
        var section = Section.none
        var attributes = [String: String]()
        var interfaceConfiguration: GatewayParsedWireGuardInterface?
        var peerConfigurations = [GatewayParsedWireGuardPeer]()

        let lines = config.split { $0.isNewline }

        for (index, line) in lines.enumerated() {
            let parsedLine = parseLine(line)
            let isLastLine = index == lines.count - 1

            if let keyValue = parsedLine.keyValue {
                try add(keyValue, to: &attributes, in: section)
            } else if !parsedLine.value.isEmpty,
                      parsedLine.value != "[interface]",
                      parsedLine.value != "[peer]" {
                throw ParseError.invalidLine(String(line))
            }

            if isLastLine || parsedLine.value == "[interface]" || parsedLine.value == "[peer]" {
                switch section {
                case .interface:
                    guard interfaceConfiguration == nil else { throw ParseError.multipleInterfaces }
                    interfaceConfiguration = try makeInterface(from: attributes)
                case .peer:
                    peerConfigurations.append(try makePeer(from: attributes))
                case .none:
                    break
                }
            }

            if parsedLine.value == "[interface]" {
                section = .interface
                attributes.removeAll()
            } else if parsedLine.value == "[peer]" {
                section = .peer
                attributes.removeAll()
            }
        }

        guard let interfaceConfiguration else {
            throw ParseError.noInterface
        }

        let publicKeys = peerConfigurations.map(\.publicKey)
        guard Set(publicKeys).count == publicKeys.count else {
            throw ParseError.multiplePeersWithSamePublicKey
        }

        return GatewayParsedWireGuardConfig(
            name: name,
            interface: interfaceConfiguration,
            peers: peerConfigurations
        )
    }

    private static func parseLine(_ line: String.SubSequence) -> (value: String, keyValue: (String, String)?) {
        let lineWithoutComment: String
        if let commentStart = line.firstIndex(of: "#") {
            lineWithoutComment = String(line[..<commentStart])
        } else {
            lineWithoutComment = String(line)
        }

        let trimmedLine = lineWithoutComment.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmedLine.lowercased()

        guard let equalsIndex = trimmedLine.firstIndex(of: "=") else {
            return (value, nil)
        }

        let key = trimmedLine[..<equalsIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        let attributeValue = trimmedLine[trimmedLine.index(after: equalsIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
        return (value, (key, attributeValue))
    }

    private static func add(
        _ keyValue: (String, String),
        to attributes: inout [String: String],
        in section: Section
    ) throws {
        let key = keyValue.0.lowercased()
        let value = keyValue.1
        let keysAllowingMultipleEntries: Set<String> = ["address", "allowedips", "dns"]

        switch section {
        case .interface:
            guard ["privatekey", "listenport", "address", "dns", "mtu"].contains(key) else {
                throw ParseError.unrecognizedInterfaceKey(keyValue.0)
            }
        case .peer:
            guard ["publickey", "presharedkey", "allowedips", "endpoint", "persistentkeepalive"].contains(key) else {
                throw ParseError.unrecognizedPeerKey(keyValue.0)
            }
        case .none:
            throw ParseError.invalidLine("\(keyValue.0) = \(value)")
        }

        if let existingValue = attributes[key] {
            guard keysAllowingMultipleEntries.contains(key) else {
                throw ParseError.multipleEntriesForKey(keyValue.0)
            }
            attributes[key] = existingValue + "," + value
        } else {
            attributes[key] = value
        }
    }

    private static func makeInterface(from attributes: [String: String]) throws -> GatewayParsedWireGuardInterface {
        guard let privateKeyString = attributes["privatekey"] else {
            throw ParseError.interfaceHasNoPrivateKey
        }
        guard isValidWireGuardKey(privateKeyString) else {
            throw ParseError.interfaceHasInvalidPrivateKey(privateKeyString)
        }

        var interface = GatewayParsedWireGuardInterface(privateKey: privateKeyString)
        if let listenPortString = attributes["listenport"] {
            guard let listenPort = UInt16(listenPortString) else {
                throw ParseError.interfaceHasInvalidListenPort(listenPortString)
            }
            interface.listenPort = listenPort
        }
        if let addressesString = attributes["address"] {
            interface.addresses = try addressesString.csvValues().map { addressString in
                guard isValidIPAddressRange(addressString) else {
                    throw ParseError.interfaceHasInvalidAddress(addressString)
                }
                return addressString
            }
        }
        if let dnsString = attributes["dns"] {
            for dnsValue in dnsString.csvValues() {
                if isValidIPAddress(dnsValue) {
                    interface.dns.append(dnsValue)
                } else if dnsValue.range(of: #"^[A-Za-z0-9.-]+$"#, options: .regularExpression) != nil {
                    interface.dnsSearch.append(dnsValue)
                } else {
                    throw ParseError.interfaceHasInvalidDNS(dnsValue)
                }
            }
        }
        if let mtuString = attributes["mtu"] {
            guard let mtu = UInt16(mtuString) else {
                throw ParseError.interfaceHasInvalidMTU(mtuString)
            }
            interface.mtu = mtu
        }
        return interface
    }

    private static func makePeer(from attributes: [String: String]) throws -> GatewayParsedWireGuardPeer {
        guard let publicKeyString = attributes["publickey"] else {
            throw ParseError.peerHasNoPublicKey
        }
        guard isValidWireGuardKey(publicKeyString) else {
            throw ParseError.peerHasInvalidPublicKey(publicKeyString)
        }

        var peer = GatewayParsedWireGuardPeer(publicKey: publicKeyString)
        if let preSharedKeyString = attributes["presharedkey"] {
            guard isValidWireGuardKey(preSharedKeyString) else {
                throw ParseError.peerHasInvalidPreSharedKey(preSharedKeyString)
            }
            peer.preSharedKey = preSharedKeyString
        }
        if let allowedIPsString = attributes["allowedips"] {
            peer.allowedIPs = try allowedIPsString.csvValues().map { allowedIPString in
                guard isValidIPAddressRange(allowedIPString) else {
                    throw ParseError.peerHasInvalidAllowedIP(allowedIPString)
                }
                return allowedIPString
            }
        }
        if let endpointString = attributes["endpoint"] {
            guard isValidEndpoint(endpointString) else {
                throw ParseError.peerHasInvalidEndpoint(endpointString)
            }
            peer.endpoint = endpointString
        }
        if let persistentKeepAliveString = attributes["persistentkeepalive"] {
            guard let persistentKeepAlive = UInt16(persistentKeepAliveString) else {
                throw ParseError.peerHasInvalidPersistentKeepAlive(persistentKeepAliveString)
            }
            peer.persistentKeepAlive = persistentKeepAlive
        }
        return peer
    }

    private static func isValidWireGuardKey(_ value: String) -> Bool {
        guard let data = Data(base64Encoded: value) else {
            return false
        }
        return data.count == 32
    }

    private static func isValidIPAddressRange(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let prefix = Int(parts[1]),
              isValidIPAddress(String(parts[0])) else {
            return false
        }

        if IPv4Address(String(parts[0])) != nil {
            return (0...32).contains(prefix)
        }
        return (0...128).contains(prefix)
    }

    private static func isValidIPAddress(_ value: String) -> Bool {
        IPv4Address(value) != nil || IPv6Address(value) != nil
    }

    private static func isValidEndpoint(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }

        let hostString: String
        let portString: String
        if value.first == "[" {
            guard let endOfHost = value.dropFirst().firstIndex(of: "]") else { return false }
            let afterHost = value.index(after: endOfHost)
            guard afterHost < value.endIndex, value[afterHost] == ":" else { return false }
            hostString = String(value[value.index(after: value.startIndex)..<endOfHost])
            portString = String(value[value.index(after: afterHost)...])
        } else {
            guard let separator = value.lastIndex(of: ":") else { return false }
            hostString = String(value[..<separator])
            portString = String(value[value.index(after: separator)...])
            guard !hostString.contains(":") else { return false }
        }

        guard !hostString.isEmpty,
              UInt16(portString) != nil else {
            return false
        }

        if isValidIPAddress(hostString) {
            return true
        }
        return hostString.range(of: #"^[A-Za-z0-9.-]+$"#, options: .regularExpression) != nil
    }
}

private extension String {
    func csvValues() -> [String] {
        split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter {
            !$0.isEmpty
        }
    }
}
