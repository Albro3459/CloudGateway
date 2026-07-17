import Testing
@testable import CloudGatewayKit

@Test func notifiesOnTransitionIntoDead() {
    #expect(CloudGatewayTunnelHealthNotification.shouldNotify(previous: nil, current: .notPassingTraffic))
    #expect(CloudGatewayTunnelHealthNotification.shouldNotify(previous: .unknown, current: .notPassingTraffic))
    #expect(CloudGatewayTunnelHealthNotification.shouldNotify(previous: .passingTraffic, current: .notPassingTraffic))
}

@Test func doesNotReNotifyWhileStillDead() {
    #expect(!CloudGatewayTunnelHealthNotification.shouldNotify(previous: .notPassingTraffic, current: .notPassingTraffic))
}

@Test func doesNotNotifyForHealthyOrUnknown() {
    #expect(!CloudGatewayTunnelHealthNotification.shouldNotify(previous: nil, current: .passingTraffic))
    #expect(!CloudGatewayTunnelHealthNotification.shouldNotify(previous: nil, current: .unknown))
}

@Test func withdrawsOnlyWhenRecoveringFromDead() {
    #expect(CloudGatewayTunnelHealthNotification.shouldWithdraw(previous: .notPassingTraffic, current: .passingTraffic))
    #expect(!CloudGatewayTunnelHealthNotification.shouldWithdraw(previous: .unknown, current: .passingTraffic))
    #expect(!CloudGatewayTunnelHealthNotification.shouldWithdraw(previous: .notPassingTraffic, current: .unknown))
}
