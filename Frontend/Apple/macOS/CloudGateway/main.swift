import AppKit
import CloudGatewayMacIPC
import Darwin

let runningIdentity: CloudGatewayMacBuildIdentity
do {
    runningIdentity = try CloudGatewayMacSignedBundle.running(
        teamIdentifier: "CRQWDQ7QQR", bundleIdentifier: "com.gocloudlaunch.gateway.macos"
    )
} catch {
    FileHandle.standardError.write(Data("CloudGateway could not verify its running build\n".utf8))
    exit(EXIT_FAILURE)
}

if CommandLine.arguments.dropFirst().first == "--controller" {
    guard CommandLine.arguments.count == 2 else { exit(EX_USAGE) }
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
} else {
    MainActor.assumeIsolated {
        let application = NSApplication.shared
        let delegate = CloudGatewayAppDelegate(identity: runningIdentity)
        application.delegate = delegate
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}
