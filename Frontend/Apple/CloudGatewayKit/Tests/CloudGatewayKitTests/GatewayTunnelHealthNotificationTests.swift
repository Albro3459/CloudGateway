import Testing
@testable import CloudGatewayKit

@Test func notifiesOnTransitionIntoDead() {
    #expect(GatewayTunnelHealthNotification.shouldNotify(previous: nil, current: .notPassingTraffic))
    #expect(GatewayTunnelHealthNotification.shouldNotify(previous: .unknown, current: .notPassingTraffic))
    #expect(GatewayTunnelHealthNotification.shouldNotify(previous: .passingTraffic, current: .notPassingTraffic))
}

@Test func doesNotReNotifyWhileStillDead() {
    #expect(!GatewayTunnelHealthNotification.shouldNotify(previous: .notPassingTraffic, current: .notPassingTraffic))
}

@Test func doesNotNotifyForHealthyOrUnknown() {
    #expect(!GatewayTunnelHealthNotification.shouldNotify(previous: nil, current: .passingTraffic))
    #expect(!GatewayTunnelHealthNotification.shouldNotify(previous: nil, current: .unknown))
}

@Test func withdrawsOnlyWhenRecoveringFromDead() {
    #expect(GatewayTunnelHealthNotification.shouldWithdraw(previous: .notPassingTraffic, current: .passingTraffic))
    #expect(!GatewayTunnelHealthNotification.shouldWithdraw(previous: .unknown, current: .passingTraffic))
    #expect(!GatewayTunnelHealthNotification.shouldWithdraw(previous: .notPassingTraffic, current: .unknown))
}
