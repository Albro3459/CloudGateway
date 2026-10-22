import Foundation
import Testing
@testable import CloudGatewayMacCore

@Test func controllerOwnershipRejectsConcurrentOwnerAndReleasesTheSameLock() throws {
    let directory = controllerLaunchTestDirectory()
    var first: CloudGatewayMacControllerOwnership? = try CloudGatewayMacControllerOwnership(directory: directory)
    #expect(first != nil)
    #expect(throws: CloudGatewayMacControllerLaunchError.busy) {
        try CloudGatewayMacControllerOwnership(directory: directory)
    }
    first = nil
    let second = try CloudGatewayMacControllerOwnership(directory: directory)
    _ = withExtendedLifetime(second) {
        #expect(throws: CloudGatewayMacControllerLaunchError.busy) {
            try CloudGatewayMacControllerOwnership(directory: directory)
        }
    }
}

@Test func controllerOwnershipRejectsSymlinksAndInsecureDirectories() throws {
    let directory = controllerLaunchTestDirectory()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
    #expect(throws: CloudGatewayMacControllerLaunchError.unsafeLocation) {
        try CloudGatewayMacControllerOwnership(directory: directory)
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    let target = directory.appendingPathComponent("target")
    try Data("untouched".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("controller-owner.lock"), withDestinationURL: target)
    #expect(throws: CloudGatewayMacControllerLaunchError.unsafeLocation) {
        try CloudGatewayMacControllerOwnership(directory: directory)
    }
    #expect(try String(contentsOf: target, encoding: .utf8) == "untouched")
    let link = directory.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
    #expect(throws: CloudGatewayMacControllerLaunchError.unsafeLocation) {
        try CloudGatewayMacControllerOwnership(directory: link)
    }
}

@Test func controllerBootstrapWritesAnOnDemandUserJobWithoutInvokingLiveLaunchd() async throws {
    let directory = controllerLaunchTestDirectory()
    let runner = ControllerLaunchTestRunner()
    let executable = URL(fileURLWithPath: "/Applications/CloudGateway.app/Contents/MacOS/CloudGateway")
    let launcher = try CloudGatewayMacControllerLauncher(executableURL: executable, directory: directory) { url, arguments in
        try await runner.run(url: url, arguments: arguments)
    }
    #expect(try await launcher.bootstrap())
    let calls = await runner.calls
    #expect(calls.count == 1)
    #expect(calls.first?.url.path == "/bin/launchctl")
    #expect(calls.first?.arguments.first == "bootstrap")
    #expect(calls.first?.arguments[1] == "user/\(getuid())")
    let plistURL = directory.appendingPathComponent("\(CloudGatewayMacControllerLauncher.serviceName).plist")
    let plist = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil) as? [String: Any])
    #expect(plist["ProgramArguments"] as? [String] == [executable.path, "--controller"])
    #expect(plist["MachServices"] as? [String: Bool] == [CloudGatewayMacControllerLauncher.serviceName: true])
    #expect(plist["LimitLoadToSessionType"] as? String == "Background")
    #expect(plist["RunAtLoad"] as? Bool == false)
    #expect(plist["ProcessType"] as? String == "Background")
    #expect(plist["UserName"] == nil)
    #expect(plist["KeepAlive"] == nil)
    let permissions = try FileManager.default.attributesOfItem(atPath: plistURL.path)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o600)
}

@Test func controllerBootstrapSerializesStartup() async throws {
    let directory = controllerLaunchTestDirectory()
    let runner = ControllerLaunchTestRunner(paused: true)
    let launcher = try CloudGatewayMacControllerLauncher(
        executableURL: URL(fileURLWithPath: "/Applications/CloudGateway.app/Contents/MacOS/CloudGateway"), directory: directory
    ) { url, arguments in try await runner.run(url: url, arguments: arguments) }
    let first = Task { try await launcher.bootstrap() }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while await runner.calls.isEmpty, clock.now < deadline { await Task.yield() }
    #expect(await runner.calls.count == 1)
    #expect(try await !launcher.bootstrap())
    await runner.release()
    #expect(try await first.value)
    #expect(try await launcher.bootstrap())
    #expect(await runner.calls.count == 2)
}

@Test func controllerBootstrapAcceptsAnAlreadyRegisteredJobAfterCheckingItsExactService() async throws {
    let runner = ControllerLaunchTestRunner(results: [.success(5), .success(0)])
    let launcher = try controllerTestLauncher(runner)
    #expect(try await launcher.bootstrap())
    let calls = await runner.calls
    #expect(calls.count == 2)
    #expect(calls.last?.url.path == "/bin/launchctl")
    #expect(calls.last?.arguments == ["print", "user/\(getuid())/\(CloudGatewayMacControllerLauncher.serviceName)"])
}

@Test(arguments: [Int32(5), 78, 113])
func controllerBootstrapPreservesRegistrationFailureStatus(status: Int32) async throws {
    let runner = ControllerLaunchTestRunner(results: [.success(status), .success(113)])
    let launcher = try controllerTestLauncher(runner)
    await #expect(throws: CloudGatewayMacControllerLaunchError.bootstrapFailed(category: .registrationFailed, exitStatus: status)) {
        try await launcher.bootstrap()
    }
    #expect(await runner.calls.count == 2)
}

@Test func controllerBootstrapSanitizesRunnerErrors() async throws {
    let runner = ControllerLaunchTestRunner(results: [.failure(NSError(domain: "untrusted subprocess details", code: 123))])
    let launcher = try controllerTestLauncher(runner)
    await #expect(throws: CloudGatewayMacControllerLaunchError.bootstrapFailed(category: .launchFailed, exitStatus: nil)) {
        try await launcher.bootstrap()
    }
    #expect(await runner.calls.count == 1)
}

@Test(arguments: [
    CloudGatewayMacControllerLaunchError.bootstrapFailed(category: .timedOut, exitStatus: nil),
    .bootstrapFailed(category: .terminated, exitStatus: 9),
])
func controllerBootstrapPreservesBoundedProcessFailures(error: CloudGatewayMacControllerLaunchError) async throws {
    let runner = ControllerLaunchTestRunner(results: [.failure(error)])
    let launcher = try controllerTestLauncher(runner)
    await #expect(throws: error) { try await launcher.bootstrap() }
    #expect(await runner.calls.count == 1)
}

@Test func controllerBootstrapPreservesOriginalStatusWhenRegistrationCheckFails() async throws {
    let runner = ControllerLaunchTestRunner(results: [
        .success(78), .failure(NSError(domain: "untrusted check details", code: 456)),
    ])
    let launcher = try controllerTestLauncher(runner)
    await #expect(throws: CloudGatewayMacControllerLaunchError.bootstrapFailed(category: .registrationCheckFailed, exitStatus: 78)) {
        try await launcher.bootstrap()
    }
    #expect(await runner.calls.count == 2)
}

@Test func controllerBootstrapPreservesCancellationDuringRegistrationCheck() async throws {
    let runner = ControllerLaunchTestRunner(results: [.success(5), .failure(CancellationError())])
    let launcher = try controllerTestLauncher(runner)
    await #expect(throws: CancellationError.self) { try await launcher.bootstrap() }
    #expect(await runner.calls.count == 2)
}

@Test func controllerBootstrapRejectsUnsafePlistAndUninstalledExecutable() async throws {
    let directory = controllerLaunchTestDirectory()
    #expect(throws: CloudGatewayMacControllerLaunchError.installationRequired) {
        try CloudGatewayMacControllerLauncher(executableURL: URL(fileURLWithPath: "/tmp/CloudGateway"), directory: directory)
    }
    let runner = ControllerLaunchTestRunner()
    let launcher = try CloudGatewayMacControllerLauncher(
        executableURL: URL(fileURLWithPath: "/Applications/CloudGateway.app/Contents/MacOS/CloudGateway"), directory: directory
    ) { url, arguments in try await runner.run(url: url, arguments: arguments) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let target = directory.appendingPathComponent("target")
    try Data("untouched".utf8).write(to: target)
    let plist = directory.appendingPathComponent("\(CloudGatewayMacControllerLauncher.serviceName).plist")
    try FileManager.default.createSymbolicLink(at: plist, withDestinationURL: target)
    await #expect(throws: CloudGatewayMacControllerLaunchError.unsafeLocation) { try await launcher.bootstrap() }
    #expect(await runner.calls.isEmpty)
    #expect(try String(contentsOf: target, encoding: .utf8) == "untouched")
}

private func controllerLaunchTestDirectory() -> URL {
    URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        .appendingPathComponent("CloudGatewayLaunchTests-\(UUID())", isDirectory: true)
}

private func controllerTestLauncher(_ runner: ControllerLaunchTestRunner) throws -> CloudGatewayMacControllerLauncher {
    try CloudGatewayMacControllerLauncher(
        executableURL: URL(fileURLWithPath: "/Applications/CloudGateway.app/Contents/MacOS/CloudGateway"),
        directory: controllerLaunchTestDirectory()
    ) { url, arguments in try await runner.run(url: url, arguments: arguments) }
}

private actor ControllerLaunchTestRunner {
    struct Call: Sendable {
        let url: URL
        let arguments: [String]
    }

    private(set) var calls: [Call] = []
    private var paused: Bool
    private let results: [Result<Int32, any Error>]
    private var continuation: CheckedContinuation<Void, Never>?

    init(paused: Bool = false, results: [Result<Int32, any Error>] = [.success(0)]) {
        self.paused = paused
        self.results = results
    }

    func run(url: URL, arguments: [String]) async throws -> Int32 {
        calls.append(Call(url: url, arguments: arguments))
        let result = results[min(calls.count - 1, results.count - 1)]
        if paused { await withCheckedContinuation { continuation = $0 } }
        return try result.get()
    }

    func release() {
        paused = false
        continuation?.resume()
        continuation = nil
    }
}
