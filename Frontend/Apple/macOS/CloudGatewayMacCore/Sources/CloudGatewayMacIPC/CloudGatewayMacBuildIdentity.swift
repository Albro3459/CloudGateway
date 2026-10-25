import CryptoKit
import Darwin
import Foundation
import Security

public struct CloudGatewayMacBuildIdentity: Codable, Equatable, Sendable {
    public let version: String
    public let build: String
    public let codeHash: String

    public init(version: String, build: String, codeHash: String) {
        self.version = version
        self.build = build
        self.codeHash = codeHash
    }

    public func validate() throws {
        let forbidden = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        guard [version, build].allSatisfy({ value in
            !value.isEmpty && value.utf8.count <= 64
                && value.unicodeScalars.allSatisfy { !forbidden.contains($0) }
        }), codeHash.utf8.count == 64,
              codeHash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw CloudGatewayMacSecretError.invalidRequest
        }
    }
}

public enum CloudGatewayMacSignedBundle {
    // Capture at startup, before an update can replace the running bundle on disk
    public static func running(
        teamIdentifier: String, bundleIdentifier: String
    ) throws -> CloudGatewayMacBuildIdentity {
        let requirement = try requirement(teamIdentifier: teamIdentifier, bundleIdentifier: bundleIdentifier)
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, SecCSFlags(), requirement) == errSecSuccess else {
            throw CloudGatewayMacSecretError.invalidRequest
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode else {
            throw CloudGatewayMacSecretError.invalidRequest
        }
        let identity = try identity(code: staticCode, requirement: requirement, bundleIdentifier: bundleIdentifier)
        guard SecCodeCheckValidity(code, SecCSFlags(), requirement) == errSecSuccess else {
            throw CloudGatewayMacSecretError.invalidRequest
        }
        return identity
    }

    public static func installed(
        at url: URL, teamIdentifier: String, bundleIdentifier: String
    ) throws -> CloudGatewayMacBuildIdentity {
        let requirement = try requirement(teamIdentifier: teamIdentifier, bundleIdentifier: bundleIdentifier)
        let path = try bundlePath(url)
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(path as CFURL, SecCSFlags(), &code) == errSecSuccess, let code else {
            throw CloudGatewayMacSecretError.invalidRequest
        }
        let identity = try identity(code: code, requirement: requirement, bundleIdentifier: bundleIdentifier)
        _ = try bundlePath(path)
        return identity
    }

    static func identity(
        signingInformation: [String: Any], bundleIdentifier: String
    ) throws -> CloudGatewayMacBuildIdentity {
        guard signingInformation[kSecCodeInfoIdentifier as String] as? String == bundleIdentifier,
              let plist = signingInformation[kSecCodeInfoPList as String] as? [String: Any],
              plist["CFBundleIdentifier"] as? String == bundleIdentifier,
              let version = plist["CFBundleShortVersionString"] as? String,
              let build = plist["CFBundleVersion"] as? String,
              let unique = signingInformation[kSecCodeInfoUnique as String] as? Data, !unique.isEmpty,
              (signingInformation[kSecCodeInfoCMS as String] as? Data)?.isEmpty == false else {
            throw CloudGatewayMacSecretError.invalidRequest
        }
        // The code directory hash covers code, resources, entitlements, and requirements. The CMS
        // wrapper is excluded because re-signing identical code changes it without changing the code
        let identity = CloudGatewayMacBuildIdentity(
            version: version, build: build,
            codeHash: SHA256.hash(data: unique).map { String(format: "%02x", $0) }.joined()
        )
        try identity.validate()
        return identity
    }

    private static func requirement(teamIdentifier: String, bundleIdentifier: String) throws -> SecRequirement {
        let text = try CloudGatewayMacPeerRequirement.make(
            teamIdentifier: teamIdentifier, bundleIdentifier: bundleIdentifier
        )
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, SecCSFlags(), &requirement) == errSecSuccess,
              let requirement else {
            throw CloudGatewayMacSecretError.invalidRequest
        }
        return requirement
    }

    private static func identity(
        code: SecStaticCode, requirement: SecRequirement, bundleIdentifier: String
    ) throws -> CloudGatewayMacBuildIdentity {
        let flags = SecCSFlags(rawValue:
            kSecCSStrictValidate | kSecCSCheckNestedCode | kSecCSCheckAllArchitectures | kSecCSRestrictSymlinks
        )
        guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else {
            throw CloudGatewayMacSecretError.invalidRequest
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            code, SecCSFlags(rawValue: kSecCSSigningInformation), &information
        ) == errSecSuccess, let information = information as? [String: Any] else {
            throw CloudGatewayMacSecretError.invalidRequest
        }
        return try identity(signingInformation: information, bundleIdentifier: bundleIdentifier)
    }

    static func bundlePath(_ url: URL) throws -> URL {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.pathComponents.contains("..") else {
            throw CloudGatewayMacSecretError.invalidRequest
        }
        let path = url.absoluteURL
        var prefix = ""
        for component in path.path.split(separator: "/") {
            prefix += "/" + component
            var info = stat()
            guard lstat(prefix, &info) == 0, info.st_mode & mode_t(S_IFMT) != mode_t(S_IFLNK) else {
                throw CloudGatewayMacSecretError.invalidRequest
            }
        }
        return path
    }
}
