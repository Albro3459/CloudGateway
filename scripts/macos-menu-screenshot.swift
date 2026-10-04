import AppKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

@MainActor
func capture(to output: URL) throws {
    guard let application = NSWorkspace.shared.runningApplications.first(where: {
        $0.bundleIdentifier == "com.gocloudlaunch.gateway.macos"
    }) else { fail("Launch CloudGateway and prepare the menu state before capturing") }
    let previousApplication = NSWorkspace.shared.frontmostApplication
    let windows = NSScreen.screens.map { screen -> NSWindow in
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.backgroundColor = NSColor(srgbRed: 0.10, green: 0.12, blue: 0.16, alpha: 1)
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.hasShadow = false
        window.orderFrontRegardless()
        return window
    }
    defer {
        NSApplication.shared.activate()
        windows.forEach { $0.close() }
        previousApplication?.activate()
    }
    print("Click the CloudGateway menu bar icon within 30 seconds. Keep the pointer above the menu")
    let deadline = Date(timeIntervalSinceNow: 30)
    var windowID: Int?
    while Date() < deadline {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        let menuWindows = (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
                           as? [[String: Any]] ?? []).filter { item in
            guard item[kCGWindowOwnerPID as String] as? Int == Int(application.processIdentifier),
                  item[kCGWindowLayer as String] as? Int == Int(CGWindowLevelForKey(.popUpMenuWindow)),
                  let bounds = item[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return false }
            return rect.width > 100 && rect.height > 100
        }
        if menuWindows.count == 1 {
            windowID = menuWindows.first?[kCGWindowNumber as String] as? Int
            break
        }
    }
    guard let windowID else {
        throw NSError(domain: "CloudGatewayScreenshot", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "No CloudGateway menu appeared within 30 seconds. Retry and click its menu bar icon"])
    }
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.8))
    try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    let capture = Process()
    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    capture.arguments = ["-x", "-l", String(windowID), output.path]
    try capture.run()
    capture.waitUntilExit()
    guard capture.terminationStatus == 0, FileManager.default.fileExists(atPath: output.path) else {
        throw NSError(domain: "CloudGatewayScreenshot", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "macOS could not capture the menu"])
    }
    print("Saved native menu screenshot: \(output.path)")
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["--permissions"] {
    _ = CGRequestScreenCaptureAccess()
    print("Allow Screen Recording for the app launching this command, then rerun it")
    exit(0)
}
guard arguments.count <= 1, arguments.first?.hasPrefix("--") != true else {
    fail("Usage: swift scripts/macos-menu-screenshot.swift [output.png | --permissions]")
}
guard CGPreflightScreenCaptureAccess() else {
    fail("Screen Recording permission is required. Run with --permissions, approve the launching app in System Settings, then retry")
}
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let output = arguments.first.map { URL(fileURLWithPath: $0) }
    ?? root.appendingPathComponent("docs/images/macos-menu.png")
MainActor.assumeIsolated {
    NSApplication.shared.setActivationPolicy(.accessory)
    do { try capture(to: output) }
    catch { fail(error.localizedDescription) }
}
