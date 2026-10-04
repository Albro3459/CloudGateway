import Foundation

public struct CloudGatewayMacExtensionVersion: Codable, Equatable, Sendable {
    public let bundleVersion: String
    public let bundleShortVersion: String

    public init?(infoDictionary: [String: Any]) {
        guard let build = infoDictionary["CFBundleVersion"] as? String,
              !build.isEmpty, build.utf8.count <= 64,
              let version = infoDictionary["CFBundleShortVersionString"] as? String,
              !version.isEmpty, version.utf8.count <= 64 else { return nil }
        bundleVersion = build
        bundleShortVersion = version
    }
}
