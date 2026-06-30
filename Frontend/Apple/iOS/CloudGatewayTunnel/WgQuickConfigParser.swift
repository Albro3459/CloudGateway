import Foundation
import WireGuardKit

enum WgQuickConfigParser {
    enum ParseError: Error {
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

    static func parse(_ config: String, named name: String?) throws -> TunnelConfiguration {
        var section = Section.none
        var attributes = [String: String]()
        var interfaceConfiguration: InterfaceConfiguration?
        var peerConfigurations = [PeerConfiguration]()

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

        return TunnelConfiguration(
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

    private static func makeInterface(from attributes: [String: String]) throws -> InterfaceConfiguration {
        guard let privateKeyString = attributes["privatekey"] else {
            throw ParseError.interfaceHasNoPrivateKey
        }
        guard let privateKey = PrivateKey(base64Key: privateKeyString) else {
            throw ParseError.interfaceHasInvalidPrivateKey(privateKeyString)
        }

        var interface = InterfaceConfiguration(privateKey: privateKey)
        if let listenPortString = attributes["listenport"] {
            guard let listenPort = UInt16(listenPortString) else {
                throw ParseError.interfaceHasInvalidListenPort(listenPortString)
            }
            interface.listenPort = listenPort
        }
        if let addressesString = attributes["address"] {
            interface.addresses = try addressesString.csvValues().map { addressString in
                guard let address = IPAddressRange(from: addressString) else {
                    throw ParseError.interfaceHasInvalidAddress(addressString)
                }
                return address
            }
        }
        if let dnsString = attributes["dns"] {
            for dnsValue in dnsString.csvValues() {
                if let dnsServer = DNSServer(from: dnsValue) {
                    interface.dns.append(dnsServer)
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

    private static func makePeer(from attributes: [String: String]) throws -> PeerConfiguration {
        guard let publicKeyString = attributes["publickey"] else {
            throw ParseError.peerHasNoPublicKey
        }
        guard let publicKey = PublicKey(base64Key: publicKeyString) else {
            throw ParseError.peerHasInvalidPublicKey(publicKeyString)
        }

        var peer = PeerConfiguration(publicKey: publicKey)
        if let preSharedKeyString = attributes["presharedkey"] {
            guard let preSharedKey = PreSharedKey(base64Key: preSharedKeyString) else {
                throw ParseError.peerHasInvalidPreSharedKey(preSharedKeyString)
            }
            peer.preSharedKey = preSharedKey
        }
        if let allowedIPsString = attributes["allowedips"] {
            peer.allowedIPs = try allowedIPsString.csvValues().map { allowedIPString in
                guard let allowedIP = IPAddressRange(from: allowedIPString) else {
                    throw ParseError.peerHasInvalidAllowedIP(allowedIPString)
                }
                return allowedIP
            }
        }
        if let endpointString = attributes["endpoint"] {
            guard let endpoint = Endpoint(from: endpointString) else {
                throw ParseError.peerHasInvalidEndpoint(endpointString)
            }
            peer.endpoint = endpoint
        }
        if let persistentKeepAliveString = attributes["persistentkeepalive"] {
            guard let persistentKeepAlive = UInt16(persistentKeepAliveString) else {
                throw ParseError.peerHasInvalidPersistentKeepAlive(persistentKeepAliveString)
            }
            peer.persistentKeepAlive = persistentKeepAlive
        }
        return peer
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
