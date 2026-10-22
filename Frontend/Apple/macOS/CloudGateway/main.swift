import AppKit
import CloudGatewayMacCLI
import CloudGatewayMacControllerIPC
import CloudGatewayMacIPC
import Darwin

let teamIdentifier = "CRQWDQ7QQR"

func verifiedRunningIdentity() throws -> CloudGatewayMacBuildIdentity {
    try CloudGatewayMacSignedBundle.running(
        teamIdentifier: teamIdentifier, bundleIdentifier: "com.gocloudlaunch.gateway.macos"
    )
}

func requireRunningIdentity() -> CloudGatewayMacBuildIdentity {
    do { return try verifiedRunningIdentity() }
    catch {
        FileHandle.standardError.write(Data("CloudGateway could not verify its running build\n".utf8))
        exit(EXIT_FAILURE)
    }
}

// Mode selection runs first so help, version, and usage errors never touch signing, Firebase, or AppKit
switch CloudGatewayMacLaunchMode(arguments: CommandLine.arguments) {
case .conflict:
    FileHandle.standardError.write(Data("CloudGateway: conflicting launch arguments\n".utf8))
    exit(2)
case .cli(let arguments):
    // A closed pipe becomes a write error instead of terminating the process
    signal(SIGPIPE, SIG_IGN)
    // Running through the cloudgateway symlink leaves Bundle.main at the link's directory
    // The bundle only supplies version strings, never the peer requirement
    let bundle = Bundle.main.executableURL.flatMap {
        Bundle(url: $0.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent())
    } ?? Bundle.main
    MainActor.assumeIsolated {
        let cli = CloudGatewayMacCLI(
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        ) { CloudGatewayMacFrontendClient(identity: try verifiedRunningIdentity(), teamIdentifier: teamIdentifier) }
        Task { exit(await cli.run(arguments)) }
        RunLoop.main.run()
    }
case .controller:
    let runningIdentity = requireRunningIdentity()
    MainActor.assumeIsolated {
        do {
            let service = try CloudGatewayMacControllerService(identity: runningIdentity)
            service.run()
            withExtendedLifetime(service) { RunLoop.main.run() }
        } catch {
            // Startup failures must not expose credential or transport details
            FileHandle.standardError.write(Data("CloudGateway controller could not start\n".utf8))
            exit(EXIT_FAILURE)
        }
    }
case .menu:
    let runningIdentity = requireRunningIdentity()
    MainActor.assumeIsolated {
        let application = NSApplication.shared
        let delegate = CloudGatewayAppDelegate(identity: runningIdentity)
        application.delegate = delegate
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}
