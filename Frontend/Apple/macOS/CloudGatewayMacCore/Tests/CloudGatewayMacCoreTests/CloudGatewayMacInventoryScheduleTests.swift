import Foundation
import Testing
@testable import CloudGatewayMacCore

@Test func macInventoryScheduleUsesActivityTiersAndCompletionDeadlines() {
    var schedule = CloudGatewayMacInventorySchedule(now: .zero)
    #expect(schedule.isDue(at: .zero))
    schedule.complete(at: .zero, succeeded: true, jitter: 0.5)
    #expect(!schedule.isDue(at: .seconds(59)))
    #expect(schedule.isDue(at: .seconds(60)))
    schedule.complete(at: .seconds(60), succeeded: true, jitter: 0.5)
    #expect(!schedule.isDue(at: .seconds(119)))
    #expect(!schedule.isDue(at: .seconds(120)))
    #expect(!schedule.isDue(at: .seconds(359)))
    #expect(schedule.isDue(at: .seconds(360)))
    #expect(schedule.isDue(at: .seconds(899)))
    #expect(!schedule.isDue(at: .seconds(900)))
    schedule.recordActivity(at: .seconds(900))
    #expect(schedule.isDue(at: .seconds(900)))
}

@Test func macInventoryScheduleFailureDoesNotRenewFreshnessAndSuccessClearsBackoff() {
    var schedule = CloudGatewayMacInventorySchedule(now: .zero)
    schedule.complete(at: .zero, succeeded: true, jitter: 0.5)
    schedule.complete(at: .seconds(30), succeeded: false, jitter: 0.5)
    #expect(!schedule.isStale(at: .seconds(59)))
    #expect(schedule.isStale(at: .seconds(60)))
    #expect(!schedule.isDue(at: .seconds(89)))
    #expect(schedule.isDue(at: .seconds(90)))
    schedule.complete(at: .seconds(90), succeeded: false, jitter: 0.5)
    schedule.recordActivity(at: .seconds(150))
    #expect(!schedule.isDue(at: .seconds(209)))
    #expect(schedule.isDue(at: .seconds(210)))
    schedule.complete(at: .seconds(210), succeeded: true, jitter: 0.5)
    #expect(!schedule.isStale(at: .seconds(269)))
    schedule.recordActivity(at: .seconds(270))
    #expect(schedule.isDue(at: .seconds(270)))
}

@Test(arguments: [(0.0, 96.0), (1.0, 144.0)])
func macInventoryScheduleJittersAndBoundsFailureRetry(jitter: Double, secondDelay: Double) {
    var schedule = CloudGatewayMacInventorySchedule(now: .zero)
    schedule.complete(at: .zero, succeeded: false, jitter: jitter)
    schedule.complete(at: .zero, succeeded: false, jitter: jitter)
    schedule.recordActivity(at: .seconds(secondDelay))
    #expect(!schedule.isDue(at: .seconds(secondDelay - 1)))
    #expect(schedule.isDue(at: .seconds(secondDelay) + .nanoseconds(1)))
    for _ in 0..<20 { schedule.complete(at: .zero, succeeded: false, jitter: jitter) }
    schedule.recordActivity(at: .seconds(900))
    #expect(schedule.isDue(at: .seconds(900)))
}

@Test func macInventoryScheduleSkipsMissedSleepIntervalsAndRetainsActivityOnAccountReset() {
    var schedule = CloudGatewayMacInventorySchedule(now: .zero)
    schedule.complete(at: .zero, succeeded: true, jitter: 0.5)
    #expect(schedule.isDue(at: .seconds(700)))
    schedule.complete(at: .seconds(700), succeeded: true, jitter: 0.5)
    #expect(!schedule.isDue(at: .seconds(701)))
    #expect(!schedule.isDue(at: .seconds(3_600)))
    schedule.resetInventory()
    #expect(schedule.isStale(at: .seconds(3_600)))
    #expect(!schedule.isDue(at: .seconds(3_600)))
}

@Test(arguments: [(0.0, 48.0), (0.5, 60.0), (1.0, 72.0)])
func macInventoryScheduleFailureRetryUsesJitterBeforeTheFiveMinuteCadence(jitter: Double, delay: Double) {
    var schedule = CloudGatewayMacInventorySchedule(now: .zero)
    schedule.complete(at: .zero, succeeded: true, jitter: jitter)
    #expect(schedule.isDue(at: .seconds(300)))
    schedule.complete(at: .seconds(300), succeeded: false, jitter: jitter)
    #expect(!schedule.isDue(at: .seconds(300 + delay - 1)))
    #expect(schedule.isDue(at: .seconds(300 + delay) + .nanoseconds(1)))
    #expect(schedule.isDue(at: .seconds(899)))
    #expect(!schedule.isDue(at: .seconds(900)))
    #expect(!schedule.isDue(at: .seconds(3_600)))
}

@Test func macInventoryScheduleSuccessRestoresTheFiveMinuteCadenceAndResetsFailureCount() {
    var schedule = CloudGatewayMacInventorySchedule(now: .zero)
    schedule.complete(at: .zero, succeeded: true, jitter: 0.5)
    schedule.complete(at: .seconds(300), succeeded: false, jitter: 0.5)
    #expect(schedule.isDue(at: .seconds(360)))
    schedule.complete(at: .seconds(360), succeeded: false, jitter: 0.5)
    #expect(!schedule.isDue(at: .seconds(479)))
    #expect(schedule.isDue(at: .seconds(480)))
    schedule.complete(at: .seconds(480), succeeded: true, jitter: 0.5)
    #expect(!schedule.isDue(at: .seconds(540)))
    #expect(!schedule.isDue(at: .seconds(779)))
    #expect(schedule.isDue(at: .seconds(780)))
    schedule.complete(at: .seconds(780), succeeded: false, jitter: 0.5)
    #expect(!schedule.isDue(at: .seconds(839)))
    #expect(schedule.isDue(at: .seconds(840)))
    #expect(!schedule.isDue(at: .seconds(900)))
}
