import Darwin
import Foundation
import Testing
import CloudGatewayMacCore
import CloudGatewayMacIPC

@Test func updateLifecycleDrainsWhenSignedCodeChangesWithoutVersionChanges() {
    let running = updateLifecycleTestIdentity(hash: "a")
    let replacement = updateLifecycleTestIdentity(hash: "b")
    var lifecycle = CloudGatewayMacUpdateLifecycle(running: running)
    lifecycle.observe(running)
    #expect(lifecycle.canAcceptMutations)
    #expect(!lifecycle.canExit(hasPendingWork: false, activeRequests: 0))

    lifecycle.observe(replacement)
    #expect(lifecycle.running == running)
    #expect(lifecycle.installed == replacement)
    #expect(lifecycle.isDraining)
    #expect(!lifecycle.canAcceptMutations)
    #expect(lifecycle.canExit(hasPendingWork: false, activeRequests: 0))
}

@Test func updateLifecycleNeverAuthorizesHandoffWithoutVerifiedInstallation() {
    let running = updateLifecycleTestIdentity(hash: "a")
    var lifecycle = CloudGatewayMacUpdateLifecycle(running: running)
    #expect(!lifecycle.canAcceptMutations)
    #expect(!lifecycle.canExit(hasPendingWork: false, activeRequests: 0))

    lifecycle.observe(nil)
    #expect(!lifecycle.isDraining)
    #expect(!lifecycle.canAcceptMutations)
    #expect(!lifecycle.canExit(hasPendingWork: false, activeRequests: 0))

    lifecycle.observe(running)
    #expect(lifecycle.canAcceptMutations)
    lifecycle.observe(nil)
    #expect(lifecycle.installed == nil)
    #expect(!lifecycle.isDraining)
    #expect(!lifecycle.canAcceptMutations)
    #expect(!lifecycle.canExit(hasPendingWork: false, activeRequests: 0))
}

@Test func updateLifecycleWaitsForPendingWorkAndEveryAcceptedRequest() {
    let running = updateLifecycleTestIdentity(hash: "a")
    let replacement = updateLifecycleTestIdentity(hash: "b")
    var lifecycle = CloudGatewayMacUpdateLifecycle(running: running)
    lifecycle.observe(running)
    lifecycle.observe(replacement)

    for (hasPendingWork, activeRequests) in [(true, 2), (true, 0), (false, 2), (false, 1)] {
        lifecycle.observe(replacement)
        #expect(lifecycle.isDraining)
        #expect(!lifecycle.canAcceptMutations)
        #expect(!lifecycle.canExit(hasPendingWork: hasPendingWork, activeRequests: activeRequests))
    }
    #expect(lifecycle.canExit(hasPendingWork: false, activeRequests: 0))
    #expect(lifecycle.isDraining)
    #expect(!lifecycle.canAcceptMutations)
}

@Test func updateLifecycleHoldsExitWhenInstallationBecomesInvalidDuringDrain() {
    let running = updateLifecycleTestIdentity(hash: "a")
    let replacement = updateLifecycleTestIdentity(hash: "b")
    var lifecycle = CloudGatewayMacUpdateLifecycle(running: running)
    lifecycle.observe(replacement)
    #expect(!lifecycle.canExit(hasPendingWork: true, activeRequests: 1))

    lifecycle.observe(nil)
    #expect(lifecycle.isDraining)
    #expect(lifecycle.installed == nil)
    #expect(!lifecycle.canAcceptMutations)
    #expect(!lifecycle.canExit(hasPendingWork: false, activeRequests: 0))

    lifecycle.observe(replacement)
    #expect(lifecycle.canExit(hasPendingWork: false, activeRequests: 0))
    #expect(!lifecycle.canAcceptMutations)
}

@Test func updateLifecycleNeverReopensAdmissionWhenOldBuildReappears() {
    let running = updateLifecycleTestIdentity(hash: "a")
    let replacement = updateLifecycleTestIdentity(hash: "b")
    var lifecycle = CloudGatewayMacUpdateLifecycle(running: running)
    lifecycle.observe(running)
    lifecycle.observe(replacement)

    for installed in [running, running, replacement, running] {
        lifecycle.observe(installed)
        #expect(lifecycle.isDraining)
        #expect(!lifecycle.canAcceptMutations)
        #expect(!lifecycle.canExit(hasPendingWork: true, activeRequests: 0))
        #expect(!lifecycle.canExit(hasPendingWork: false, activeRequests: 1))
    }
    #expect(lifecycle.installed == running)
    #expect(lifecycle.canExit(hasPendingWork: false, activeRequests: 0))
}

@Test func controllerUpdateStorageRoundTripsAndAtomicallyReplacesPrivateReceipts() throws {
    let directory = try controllerUpdateTestDirectory()
    #expect(try CloudGatewayMacControllerUpdateStorage.load(directory: directory) == nil)
    let original = Data("{\"receipts\":[\"accepted\"]}".utf8)
    let replacement = Data("{\"receipts\":[\"completed\",\"accepted\"]}".utf8)
    try CloudGatewayMacControllerUpdateStorage.save(original, directory: directory)
    #expect(try CloudGatewayMacControllerUpdateStorage.load(directory: directory) == original)

    let receipts = directory.appendingPathComponent("controller-receipts.json")
    let reader = try FileHandle(forReadingFrom: receipts)
    defer { try? reader.close() }
    try CloudGatewayMacControllerUpdateStorage.save(replacement, directory: directory)
    #expect(try reader.readToEnd() == original)
    #expect(try CloudGatewayMacControllerUpdateStorage.load(directory: directory) == replacement)

    let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
    let fileAttributes = try FileManager.default.attributesOfItem(atPath: receipts.path)
    #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    #expect((fileAttributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid())
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["controller-receipts.json"])
}

@Test func controllerUpdateStorageAccepts64KiBAndRejectsLargerWritesWithoutLosingReceipts() throws {
    let directory = try controllerUpdateTestDirectory()
    let maximum = Data(repeating: 0x61, count: 64 * 1024)
    try CloudGatewayMacControllerUpdateStorage.save(maximum, directory: directory)
    #expect(try CloudGatewayMacControllerUpdateStorage.load(directory: directory) == maximum)

    #expect(throws: CloudGatewayMacControllerLaunchError.unavailable) {
        try CloudGatewayMacControllerUpdateStorage.save(Data(repeating: 0x62, count: 64 * 1024 + 1), directory: directory)
    }
    #expect(try CloudGatewayMacControllerUpdateStorage.load(directory: directory) == maximum)
}

@Test func controllerUpdateStorageKeepsRequestAndExtensionRecordsIndependent() throws {
    let directory = try controllerUpdateTestDirectory()
    let requests = Data("accepted request".utf8)
    let pending = Data("pending extension update".utf8)
    let completed = Data("completed extension update".utf8)
    try CloudGatewayMacControllerUpdateStorage.save(requests, directory: directory)
    #expect(try CloudGatewayMacControllerUpdateStorage.load(directory: directory, record: .extensionUpdates) == nil)

    try CloudGatewayMacControllerUpdateStorage.save(pending, directory: directory, record: .extensionUpdates)
    let updates = directory.appendingPathComponent("controller-extension-updates.json")
    let reader = try FileHandle(forReadingFrom: updates)
    defer { try? reader.close() }
    try CloudGatewayMacControllerUpdateStorage.save(completed, directory: directory, record: .extensionUpdates)
    #expect(try reader.readToEnd() == pending)
    #expect(try CloudGatewayMacControllerUpdateStorage.load(directory: directory, record: .extensionUpdates) == completed)
    #expect(try CloudGatewayMacControllerUpdateStorage.load(directory: directory) == requests)

    #expect(throws: CloudGatewayMacControllerLaunchError.unavailable) {
        try CloudGatewayMacControllerUpdateStorage.save(
            Data(repeating: 0x61, count: 64 * 1024 + 1), directory: directory, record: .extensionUpdates
        )
    }
    #expect(try CloudGatewayMacControllerUpdateStorage.load(directory: directory, record: .extensionUpdates) == completed)
    #expect(try CloudGatewayMacControllerUpdateStorage.load(directory: directory) == requests)
}

@Test func controllerUpdateStorageRejectsOversizedReceiptsOnDisk() throws {
    let directory = try controllerUpdateTestDirectory()
    try CloudGatewayMacControllerUpdateStorage.save(Data("original".utf8), directory: directory)
    let receipts = directory.appendingPathComponent("controller-receipts.json")
    try Data(repeating: 0x61, count: 64 * 1024 + 1).write(to: receipts)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receipts.path)

    #expect(throws: CloudGatewayMacControllerLaunchError.unavailable) {
        try CloudGatewayMacControllerUpdateStorage.load(directory: directory)
    }
}

@Test func controllerUpdateStorageRejectsReceiptSymlinksWithoutChangingTheirTargets() throws {
    let directory = try controllerUpdateTestDirectory()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let target = directory.appendingPathComponent("target")
    let original = Data("untouched".utf8)
    try original.write(to: target)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    let receipts = directory.appendingPathComponent("controller-receipts.json")
    try FileManager.default.createSymbolicLink(at: receipts, withDestinationURL: target)

    #expect(throws: CloudGatewayMacControllerLaunchError.unsafeLocation) {
        try CloudGatewayMacControllerUpdateStorage.load(directory: directory)
    }
    #expect(throws: CloudGatewayMacControllerLaunchError.unsafeLocation) {
        try CloudGatewayMacControllerUpdateStorage.save(Data("replacement".utf8), directory: directory)
    }
    #expect(try Data(contentsOf: target) == original)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: receipts.path) == target.path)
}

@Test func controllerUpdateStorageRejectsSymlinkDirectoriesAndParents() throws {
    let directory = try controllerUpdateTestDirectory()
    let original = Data("original".utf8)
    try CloudGatewayMacControllerUpdateStorage.save(original, directory: directory)
    let alias = directory.appendingPathComponent("alias", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)

    for unsafeDirectory in [alias, alias.appendingPathComponent("child", isDirectory: true)] {
        #expect(throws: CloudGatewayMacControllerLaunchError.unsafeLocation) {
            try CloudGatewayMacControllerUpdateStorage.load(directory: unsafeDirectory)
        }
        #expect(throws: CloudGatewayMacControllerLaunchError.unsafeLocation) {
            try CloudGatewayMacControllerUpdateStorage.save(Data("replacement".utf8), directory: unsafeDirectory)
        }
    }
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("child").path))
    #expect(try CloudGatewayMacControllerUpdateStorage.load(directory: directory) == original)
}

@Test func controllerUpdateStorageRejectsFIFOWithoutOpeningAWriter() throws {
    let directory = try controllerUpdateTestDirectory()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let receipts = directory.appendingPathComponent("controller-receipts.json")
    try #require(mkfifo(receipts.path, 0o600) == 0)

    #expect(throws: CloudGatewayMacControllerLaunchError.unsafeLocation) {
        try CloudGatewayMacControllerUpdateStorage.load(directory: directory)
    }
    #expect(throws: CloudGatewayMacControllerLaunchError.unsafeLocation) {
        try CloudGatewayMacControllerUpdateStorage.save(Data("replacement".utf8), directory: directory)
    }
    var info = stat()
    try #require(lstat(receipts.path, &info) == 0)
    #expect(info.st_mode & mode_t(S_IFMT) == mode_t(S_IFIFO))
}

@Test(arguments: [0o755, 0o770, 0o1700])
func controllerUpdateStorageRejectsNonprivateDirectories(permissions: Int) throws {
    let directory = try controllerUpdateTestDirectory()
    let original = Data("original".utf8)
    try CloudGatewayMacControllerUpdateStorage.save(original, directory: directory)
    try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: directory.path)

    #expect(throws: CloudGatewayMacControllerLaunchError.unsafeLocation) {
        try CloudGatewayMacControllerUpdateStorage.load(directory: directory)
    }
    #expect(throws: CloudGatewayMacControllerLaunchError.unsafeLocation) {
        try CloudGatewayMacControllerUpdateStorage.save(Data("replacement".utf8), directory: directory)
    }
    #expect(try Data(contentsOf: directory.appendingPathComponent("controller-receipts.json")) == original)
}

@Test(arguments: [0o644, 0o660, 0o400, 0o1600])
func controllerUpdateStorageRejectsWrongReceiptModes(permissions: Int) throws {
    let directory = try controllerUpdateTestDirectory()
    let original = Data("original".utf8)
    try CloudGatewayMacControllerUpdateStorage.save(original, directory: directory)
    let receipts = directory.appendingPathComponent("controller-receipts.json")
    try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: receipts.path)

    #expect(throws: CloudGatewayMacControllerLaunchError.unsafeLocation) {
        try CloudGatewayMacControllerUpdateStorage.load(directory: directory)
    }
    #expect(throws: CloudGatewayMacControllerLaunchError.unsafeLocation) {
        try CloudGatewayMacControllerUpdateStorage.save(Data("replacement".utf8), directory: directory)
    }
    #expect(try Data(contentsOf: receipts) == original)
}

private func updateLifecycleTestIdentity(hash: Character) -> CloudGatewayMacBuildIdentity {
    CloudGatewayMacBuildIdentity(version: "1.2.0", build: "42", codeHash: String(repeating: String(hash), count: 64))
}

private func controllerUpdateTestDirectory() throws -> URL {
    let canonical = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
    defer { free(canonical) }
    return URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
        .appendingPathComponent("CloudGatewayUpdateTests-\(UUID())", isDirectory: true)
}
