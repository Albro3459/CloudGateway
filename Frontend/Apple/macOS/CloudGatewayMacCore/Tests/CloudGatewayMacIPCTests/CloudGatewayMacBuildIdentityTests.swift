import Foundation
import Darwin
import Security
import Testing
@testable import CloudGatewayMacIPC

@Test func macBuildIdentityRoundTripsAndAcceptsBoundedMetadata() throws {
    let identity = CloudGatewayMacBuildIdentity(
        version: String(repeating: "1", count: 64), build: "42", codeHash: String(repeating: "a1", count: 32)
    )
    try identity.validate()
    let encoded = try JSONEncoder().encode(identity)
    #expect(encoded.count <= CloudGatewayMacSecretBounds.responseBytes)
    let decoded = try JSONDecoder().decode(CloudGatewayMacBuildIdentity.self, from: encoded)
    try decoded.validate()
    #expect(decoded == identity)
}

@Test(arguments: ["", " ", "1\n2", "1\02", "1 2", String(repeating: "1", count: 65)])
func macBuildIdentityRejectsInvalidVersionAndBuild(value: String) {
    let hash = String(repeating: "0", count: 64)
    #expect(throws: CloudGatewayMacSecretError.invalidRequest) {
        try CloudGatewayMacBuildIdentity(version: value, build: "1", codeHash: hash).validate()
    }
    #expect(throws: CloudGatewayMacSecretError.invalidRequest) {
        try CloudGatewayMacBuildIdentity(version: "1", build: value, codeHash: hash).validate()
    }
}

@Test(arguments: [
    "", String(repeating: "a", count: 63), String(repeating: "a", count: 65),
    String(repeating: "A", count: 64), String(repeating: "g", count: 64), String(repeating: "é", count: 32)
])
func macBuildIdentityRejectsInvalidCodeHash(hash: String) {
    #expect(throws: CloudGatewayMacSecretError.invalidRequest) {
        try CloudGatewayMacBuildIdentity(version: "1.2", build: "42", codeHash: hash).validate()
    }
}

@Test func macBuildIdentityDistinguishesCodeChangesButNotResigningAtTheSameVersion() throws {
    let information = macBuildSigningInformation()
    let identity = try CloudGatewayMacSignedBundle.identity(
        signingInformation: information, bundleIdentifier: macBuildBundleIdentifier
    )
    #expect(identity.codeHash == "039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81")
    var changedCode = information
    changedCode[kSecCodeInfoUnique as String] = Data([4, 5, 6])
    let replacement = try CloudGatewayMacSignedBundle.identity(
        signingInformation: changedCode, bundleIdentifier: macBuildBundleIdentifier
    )
    #expect(replacement.version == identity.version)
    #expect(replacement.build == identity.build)
    #expect(replacement.codeHash != identity.codeHash)
    var resigned = information
    resigned[kSecCodeInfoCMS as String] = Data([4, 5, 6])
    #expect(try CloudGatewayMacSignedBundle.identity(
        signingInformation: resigned, bundleIdentifier: macBuildBundleIdentifier
    ) == identity)
}

@Test(arguments: [kSecCodeInfoUnique as String, kSecCodeInfoCMS as String])
func macBuildIdentityRequiresCodeDirectoryAndCMS(key: String) {
    var information = macBuildSigningInformation()
    let values: [Any?] = [nil, Data(), "untrusted"]
    for value in values {
        information[key] = value
        #expect(throws: CloudGatewayMacSecretError.invalidRequest) {
            try CloudGatewayMacSignedBundle.identity(
                signingInformation: information, bundleIdentifier: macBuildBundleIdentifier
            )
        }
    }
}

@Test func macBuildIdentityRequiresMatchingSignedBundleMetadata() throws {
    var information = macBuildSigningInformation()
    information[kSecCodeInfoIdentifier as String] = "com.example.other"
    #expect(throws: CloudGatewayMacSecretError.invalidRequest) {
        try CloudGatewayMacSignedBundle.identity(
            signingInformation: information, bundleIdentifier: macBuildBundleIdentifier
        )
    }
    let values: [Any?] = [nil, 42, ""]
    for key in ["CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion"] {
        for value in values {
            information = macBuildSigningInformation()
            var plist = try #require(information[kSecCodeInfoPList as String] as? [String: Any])
            plist[key] = value
            information[kSecCodeInfoPList as String] = plist
            #expect(throws: CloudGatewayMacSecretError.invalidRequest) {
                try CloudGatewayMacSignedBundle.identity(
                    signingInformation: information, bundleIdentifier: macBuildBundleIdentifier
                )
            }
        }
    }
}

@Test func macSignedBundleRejectsUnsignedInstalledBundle() throws {
    let root = try macBuildFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let bundle = root.appendingPathComponent("Fixture.app", isDirectory: true)
    let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
    let executables = contents.appendingPathComponent("MacOS", isDirectory: true)
    try FileManager.default.createDirectory(at: executables, withIntermediateDirectories: true)
    let plist = [
        "CFBundleIdentifier": macBuildBundleIdentifier, "CFBundleExecutable": "Fixture",
        "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "1.2", "CFBundleVersion": "42"
    ]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        .write(to: contents.appendingPathComponent("Info.plist"))
    let executable = executables.appendingPathComponent("Fixture")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    #expect(throws: CloudGatewayMacSecretError.invalidRequest) {
        try CloudGatewayMacSignedBundle.installed(
            at: bundle, teamIdentifier: "ABCDEFGHIJ", bundleIdentifier: macBuildBundleIdentifier
        )
    }
}

@Test func macSignedBundleRejectsSymlinksAtTheBundleAndItsAncestors() throws {
    let root = try macBuildFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let bundle = root.appendingPathComponent("Fixture.app", isDirectory: true)
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    #expect(try CloudGatewayMacSignedBundle.bundlePath(bundle) == bundle)
    let link = root.appendingPathComponent("Linked.app")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: bundle)
    let parentLink = root.appendingPathComponent("LinkedParent")
    try FileManager.default.createSymbolicLink(at: parentLink, withDestinationURL: root)
    for path in [link, parentLink.appendingPathComponent("Fixture.app")] {
        #expect(throws: CloudGatewayMacSecretError.invalidRequest) {
            try CloudGatewayMacSignedBundle.bundlePath(path)
        }
    }
}

@Test func macSignedBundleRejectsRequirementInjectionAndNonFileURLs() throws {
    let url = try #require(URL(string: "https://example.com/Fixture.app"))
    #expect(throws: CloudGatewayMacSecretError.invalidRequest) {
        try CloudGatewayMacSignedBundle.installed(
            at: url, teamIdentifier: "ABCDEFGHIJ", bundleIdentifier: macBuildBundleIdentifier
        )
    }
    #expect(throws: CloudGatewayMacSecretError.invalidRequest) {
        try CloudGatewayMacSignedBundle.running(teamIdentifier: "ABCDEFGHIJ", bundleIdentifier: "a\" or true")
    }
}

private let macBuildBundleIdentifier = "com.example.cloudgateway.fixture"

private func macBuildSigningInformation() -> [String: Any] {
    [
        kSecCodeInfoIdentifier as String: macBuildBundleIdentifier,
        kSecCodeInfoPList as String: [
            "CFBundleIdentifier": macBuildBundleIdentifier,
            "CFBundleShortVersionString": "1.2", "CFBundleVersion": "42"
        ],
        kSecCodeInfoUnique as String: Data([1, 2, 3]),
        kSecCodeInfoCMS as String: Data([7, 8, 9])
    ]
}

private func macBuildFixtureDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("CloudGatewayMacBuildIdentityTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let canonical = try #require(realpath(root.path, nil))
    defer { free(canonical) }
    return URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
}
