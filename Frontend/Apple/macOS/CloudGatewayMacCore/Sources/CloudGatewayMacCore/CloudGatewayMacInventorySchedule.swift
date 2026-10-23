import Foundation

struct CloudGatewayMacInventorySchedule {
    private var lastActivity: Duration
    private var lastSuccess: Duration?
    private var lastCompletion: Duration?
    private var retryAfter: Duration?
    private var failures = 0

    init(now: Duration) {
        lastActivity = now
    }

    mutating func recordActivity(at now: Duration) {
        lastActivity = now
    }

    func isStale(at now: Duration) -> Bool {
        guard let lastSuccess else { return true }
        return now - lastSuccess >= .seconds(60)
    }

    func isDue(at now: Duration) -> Bool {
        let idle = now - lastActivity
        guard !isIdle(at: now) else { return false }
        if let retryAfter { return now >= retryAfter }
        let interval: Duration = idle < .seconds(120) ? .seconds(60) : .seconds(300)
        if let lastCompletion, now - lastCompletion < interval { return false }
        return true
    }

    func isIdle(at now: Duration) -> Bool {
        now - lastActivity >= .seconds(900)
    }

    mutating func complete(at now: Duration, succeeded: Bool, jitter: Double) {
        lastCompletion = now
        if succeeded {
            lastSuccess = now
            failures = 0
            retryAfter = nil
        } else {
            failures = min(failures + 1, 5)
            let delay = min(900, 60 * pow(2, Double(failures - 1)) * (0.8 + 0.4 * min(1, max(0, jitter))))
            retryAfter = now + .seconds(delay)
        }
    }

    mutating func resetInventory() {
        lastSuccess = nil
        lastCompletion = nil
        retryAfter = nil
        failures = 0
    }
}
