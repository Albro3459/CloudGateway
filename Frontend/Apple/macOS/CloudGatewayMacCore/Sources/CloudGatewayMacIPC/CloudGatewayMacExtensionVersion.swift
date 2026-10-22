import Foundation

public struct CloudGatewayMacExtensionVersion: Codable, Equatable, Sendable {
    public let bundleVersion: String
    public let bundleShortVersion: String
    public let codeHash: String?

    public init?(infoDictionary: [String: Any], codeHash: String? = nil) {
        guard let build = infoDictionary["CFBundleVersion"] as? String,
              !build.isEmpty, build.utf8.count <= 64,
              let version = infoDictionary["CFBundleShortVersionString"] as? String,
              !version.isEmpty, version.utf8.count <= 64,
              codeHash.map(Self.isValidCodeHash) ?? true else { return nil }
        bundleVersion = build
        bundleShortVersion = version
        self.codeHash = codeHash
    }

    public var hasCodeHash: Bool { codeHash.map(Self.isValidCodeHash) ?? false }

    private static func isValidCodeHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
