import Foundation

/// Direct port of `Frontend/Web/src/helpers/meshValidation.ts`. Keep in lockstep with that file.
public enum CloudGatewayMeshValidation {
    public static func isValidWireGuardPublicKey(_ value: String?) -> Bool {
        guard let value, value.count == 44, value.hasSuffix("=") else { return false }
        guard value.dropLast().allSatisfy(isBase64KeyCharacter) else { return false }
        return Data(base64Encoded: value)?.count == 32
    }

    public static func isValidEndpointHostname(_ value: String?) -> Bool {
        guard let value, value.count >= 1, value.count <= 253 else { return false }
        if parseIPv4(value) != nil { return true }
        if parseIPv6(value) != nil { return true }
        return value.components(separatedBy: ".").allSatisfy(isValidHostnameLabel)
    }

    public static func isValidMeshNetworkSyntaxV4(_ value: String?) -> Bool {
        guard let value else { return false }
        let parts = value.components(separatedBy: "/")
        guard parts.count == 2, parts[1] == "24" else { return false }
        guard let octets = parseIPv4(parts[0]), octets[3] == 0 else { return false }
        return parts[0] == octets.map(String.init).joined(separator: ".")
    }

    public static func isValidMeshNetworkV4(_ value: String?) -> Bool {
        guard let value, isValidMeshNetworkSyntaxV4(value) else { return false }
        guard let octets = parseIPv4(value.components(separatedBy: "/")[0]) else { return false }
        return octets[0] == 10 && octets[1] == 0
    }

    public static func isValidMeshNetworkSyntaxV6(_ value: String?) -> Bool {
        guard let value else { return false }
        let parts = value.components(separatedBy: "/")
        guard parts.count == 2, parts[1] == "64" else { return false }
        guard let words = parseIPv6(parts[0]), formatIPv6Canonical(words) == parts[0] else { return false }
        return words[4] == 0 && words[5] == 0 && words[6] == 0 && words[7] == 0
    }

    public static func isValidMeshNetworkV6(_ value: String?) -> Bool {
        guard let value, isValidMeshNetworkSyntaxV6(value) else { return false }
        guard let words = parseIPv6(value.components(separatedBy: "/")[0]) else { return false }
        return words[0] == 0xfd42 && words[1] == 0x42 && words[2] == 0x42
    }

    public static func isValidMeshEndpointPort(_ value: Int?) -> Bool {
        guard let value else { return false }
        return value >= 1 && value <= 65535
    }

    public static func networksOverlap(_ lhs: String, _ rhs: String) -> Bool {
        if isValidMeshNetworkV4(lhs) && isValidMeshNetworkV4(rhs) {
            let lhsThird = Int(lhs.components(separatedBy: ".")[2])
            let rhsThird = Int(rhs.components(separatedBy: ".")[2])
            return lhsThird == rhsThird
        }
        if isValidMeshNetworkV6(lhs) && isValidMeshNetworkV6(rhs) {
            guard let lhsWords = parseIPv6(lhs.components(separatedBy: "/")[0]),
                  let rhsWords = parseIPv6(rhs.components(separatedBy: "/")[0]) else { return false }
            return lhsWords[0..<4] == rhsWords[0..<4]
        }
        return false
    }

    // MARK: - Private helpers

    private static func isBase64KeyCharacter(_ c: Character) -> Bool {
        ("A"..."Z").contains(c) || ("a"..."z").contains(c) || ("0"..."9").contains(c) || c == "+" || c == "/"
    }

    private static func isASCIIDigit(_ c: Character) -> Bool {
        ("0"..."9").contains(c)
    }

    private static func isHexDigitCharacter(_ c: Character) -> Bool {
        ("0"..."9").contains(c) || ("a"..."f").contains(c) || ("A"..."F").contains(c)
    }

    private static func isAlphanumeric(_ c: Character) -> Bool {
        ("A"..."Z").contains(c) || ("a"..."z").contains(c) || ("0"..."9").contains(c)
    }

    private static func isValidHostnameLabel(_ label: String) -> Bool {
        guard label.count >= 1, label.count <= 63 else { return false }
        let chars = Array(label)
        guard isAlphanumeric(chars[0]), isAlphanumeric(chars[chars.count - 1]) else { return false }
        return chars.allSatisfy { isAlphanumeric($0) || $0 == "-" }
    }

    private static func parseIPv4(_ value: String) -> [Int]? {
        let parts = value.components(separatedBy: ".")
        guard parts.count == 4 else { return nil }
        var octets: [Int] = []
        for part in parts {
            guard part.count >= 1, part.count <= 3, part.allSatisfy(isASCIIDigit) else { return nil }
            if part.count > 1 && part.hasPrefix("0") { return nil }
            guard let parsed = Int(part), parsed >= 0, parsed <= 255 else { return nil }
            octets.append(parsed)
        }
        return octets
    }

    private static func parseIPv6(_ value: String) -> [Int]? {
        guard !value.isEmpty, !value.contains(".") else { return nil }
        let halves = value.components(separatedBy: "::")
        guard halves.count <= 2 else { return nil }

        func parseHalf(_ half: String) -> [Int]? {
            guard !half.isEmpty else { return [] }
            let parts = half.components(separatedBy: ":")
            var words: [Int] = []
            for part in parts {
                guard part.count >= 1, part.count <= 4, part.allSatisfy(isHexDigitCharacter) else { return nil }
                words.append(Int(part, radix: 16)!)
            }
            return words
        }

        guard let left = parseHalf(halves[0]) else { return nil }
        guard let right = parseHalf(halves.count == 2 ? halves[1] : "") else { return nil }
        if halves.count == 1 {
            return left.count == 8 ? left : nil
        }
        let gap = 8 - left.count - right.count
        guard gap >= 1 else { return nil }
        return left + Array(repeating: 0, count: gap) + right
    }

    /// Hand-ported longest-zero-run compression; must not use `IPv6Address`/`inet_ntop` so canonical
    /// form matches the web's `formatIPv6Canonical` byte for byte.
    private static func formatIPv6Canonical(_ words: [Int]) -> String {
        let parts = words.map { String($0, radix: 16) }
        var bestStart = -1
        var bestLength = 0
        var start = 0
        while start < words.count {
            if words[start] != 0 {
                start += 1
                continue
            }
            var end = start
            while end < words.count && words[end] == 0 { end += 1 }
            if end - start > bestLength {
                bestStart = start
                bestLength = end - start
            }
            start = end
        }
        if bestLength < 2 { return parts.joined(separator: ":") }
        let left = parts[0..<bestStart].joined(separator: ":")
        let right = parts[(bestStart + bestLength)...].joined(separator: ":")
        return "\(left)::\(right)"
    }
}
