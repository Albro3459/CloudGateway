import AppKit
import CloudGatewayMacCLI
import CloudGatewayMacCore
import Foundation

extension CloudGatewayMacCLILoginEffects {
    static var production: Self {
        .init(qrMatrix: CloudGatewayMacQRCode.matrix, copy: Self.copy, open: Self.open)
    }
    @MainActor static func copy(_ url: URL) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    @MainActor static func open(_ url: URL) -> Bool { NSWorkspace.shared.open(url) }
}
