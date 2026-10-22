import CloudGatewayMacIPC

public struct CloudGatewayMacUpdateLifecycle: Sendable {
    public let running: CloudGatewayMacBuildIdentity
    public private(set) var installed: CloudGatewayMacBuildIdentity?
    public private(set) var isDraining = false

    public init(running: CloudGatewayMacBuildIdentity) {
        self.running = running
    }

    public mutating func observe(_ installed: CloudGatewayMacBuildIdentity?) {
        self.installed = installed
        if let installed, installed != running { isDraining = true }
    }

    public var canAcceptMutations: Bool { !isDraining && installed == running }

    public func canExit(hasPendingWork: Bool, activeRequests: Int) -> Bool {
        isDraining && installed != nil && !hasPendingWork && activeRequests == 0
    }
}
