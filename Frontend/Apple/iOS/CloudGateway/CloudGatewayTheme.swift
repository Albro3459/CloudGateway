import SwiftUI

struct CloudGatewayTheme {
    let page = Color(hex: 0x030712)
    let scrim = Color(hex: 0x000000)
    let card = Color(hex: 0x101828)
    let inset = Color(hex: 0x1e2939)
    let insetStrong = Color(hex: 0x364153)
    let insetStrongHover = Color(hex: 0x4a5565)
    let disabled = Color(hex: 0x1e2939)

    let nav = Color(hex: 0x162456)
    let navButton = Color(hex: 0x1e2939)
    let navButtonHover = Color(hex: 0x364153)

    let primary = Color(hex: 0x155dfc)
    let primaryHover = Color(hex: 0x2b7fff)
    let primarySoft = Color(hex: 0x162456)
    let primarySoftEdge = Color(hex: 0x1c398e)
    let accent = Color(hex: 0x51a2ff)
    let accentStrong = Color(hex: 0x8ec5ff)
    let focus = Color(hex: 0x2b7fff)
    let focusSoft = Color(hex: 0x1c398e)

    let content = Color(hex: 0xf3f4f6)
    let contentSecondary = Color(hex: 0xd1d5dc)
    let contentMuted = Color(hex: 0x99a1af)
    let contentFaint = Color(hex: 0x6a7282)
    let contentDisabled = Color(hex: 0x4a5565)

    let edge = Color(hex: 0x364153)
    let edgeSubtle = Color(hex: 0x1e2939)
    let edgeFaint = Color(hex: 0x1e2939)
    let neutralStrong = Color(hex: 0x4a5565)

    let success = Color(hex: 0x008236)
    let successSoft = Color(hex: 0x032e15)
    let successStrong = Color(hex: 0x7bf1a8)
    let successSoftEdge = Color(hex: 0x0d542b)

    let warningSoft = Color(hex: 0x432004)
    let warningStrong = Color(hex: 0xffdf20)
    let warningSoftEdge = Color(hex: 0x733e0a)

    let danger = Color(hex: 0xe7000b)
    let dangerButton = Color(hex: 0xc10007)
    let dangerButtonHover = Color(hex: 0x9f0712)
    let dangerContent = Color(hex: 0xff6467)
    let dangerSoft = Color(hex: 0x460809)
    let dangerStrong = Color(hex: 0xffa2a2)
    let dangerSoftEdge = Color(hex: 0x82181a)
}

private struct CloudGatewayThemeKey: EnvironmentKey {
    static let defaultValue = CloudGatewayTheme()
}

extension EnvironmentValues {
    var cloudGatewayTheme: CloudGatewayTheme {
        get { self[CloudGatewayThemeKey.self] }
        set { self[CloudGatewayThemeKey.self] = newValue }
    }
}

extension Color {
    init(hex: UInt32) {
        let red = Double((hex >> 16) & 0xff) / 255
        let green = Double((hex >> 8) & 0xff) / 255
        let blue = Double(hex & 0xff) / 255
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }
}
