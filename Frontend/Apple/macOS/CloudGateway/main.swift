import AppKit
import Darwin

if CommandLine.arguments.dropFirst().first == "--controller" {
    guard CommandLine.arguments.count == 2 else { exit(EX_USAGE) }
    MainActor.assumeIsolated {
        do {
            let service = try CloudGatewayMacControllerService()
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
        let delegate = CloudGatewayAppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}
