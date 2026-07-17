import Foundation

public struct GatewayTunnelHealthTiming: Equatable, Sendable {
    public let runtimePollInterval: Duration
    public let runtimeReadDeadline: Duration
    public let neverHandshakeGrace: Duration
    public let staleHandshake: Duration
    public let oneWayFlatDuration: Duration
    public let runtimeUnavailableDuration: Duration
    public let pathQuietPeriod: Duration
    public let pathSettlingCap: Duration
    public let recoveryVerificationDuration: Duration
    public let recoveryOperationDeadline: Duration
    public let healthyPollsToRecover: Int
    public let persistenceHeartbeat: Duration
    public let snapshotFreshness: Duration
    public let snapshotFutureTolerance: Duration
    public let notificationOperationDeadline: Duration
    public let notificationInitialRetryDelay: Duration
    public let notificationMaximumRetryDelay: Duration

    public init(
        runtimePollInterval: Duration,
        runtimeReadDeadline: Duration,
        neverHandshakeGrace: Duration,
        staleHandshake: Duration,
        oneWayFlatDuration: Duration,
        runtimeUnavailableDuration: Duration,
        pathQuietPeriod: Duration,
        pathSettlingCap: Duration,
        recoveryVerificationDuration: Duration,
        recoveryOperationDeadline: Duration,
        healthyPollsToRecover: Int,
        persistenceHeartbeat: Duration,
        snapshotFreshness: Duration,
        snapshotFutureTolerance: Duration,
        notificationOperationDeadline: Duration,
        notificationInitialRetryDelay: Duration,
        notificationMaximumRetryDelay: Duration
    ) {
        let durations = [
            runtimePollInterval,
            runtimeReadDeadline,
            neverHandshakeGrace,
            staleHandshake,
            oneWayFlatDuration,
            runtimeUnavailableDuration,
            pathQuietPeriod,
            pathSettlingCap,
            recoveryVerificationDuration,
            recoveryOperationDeadline,
            persistenceHeartbeat,
            snapshotFreshness,
            snapshotFutureTolerance,
            notificationOperationDeadline,
            notificationInitialRetryDelay,
            notificationMaximumRetryDelay
        ]
        precondition(durations.allSatisfy { $0 >= .zero })
        precondition(runtimePollInterval > .zero)
        precondition(healthyPollsToRecover >= 1)
        precondition(persistenceHeartbeat < snapshotFreshness)
        precondition(pathQuietPeriod <= pathSettlingCap)
        precondition(notificationInitialRetryDelay > .zero)
        precondition(notificationInitialRetryDelay <= notificationMaximumRetryDelay)

        self.runtimePollInterval = runtimePollInterval
        self.runtimeReadDeadline = runtimeReadDeadline
        self.neverHandshakeGrace = neverHandshakeGrace
        self.staleHandshake = staleHandshake
        self.oneWayFlatDuration = oneWayFlatDuration
        self.runtimeUnavailableDuration = runtimeUnavailableDuration
        self.pathQuietPeriod = pathQuietPeriod
        self.pathSettlingCap = pathSettlingCap
        self.recoveryVerificationDuration = recoveryVerificationDuration
        self.recoveryOperationDeadline = recoveryOperationDeadline
        self.healthyPollsToRecover = healthyPollsToRecover
        self.persistenceHeartbeat = persistenceHeartbeat
        self.snapshotFreshness = snapshotFreshness
        self.snapshotFutureTolerance = snapshotFutureTolerance
        self.notificationOperationDeadline = notificationOperationDeadline
        self.notificationInitialRetryDelay = notificationInitialRetryDelay
        self.notificationMaximumRetryDelay = notificationMaximumRetryDelay
    }

    public static let production = GatewayTunnelHealthTiming(
        runtimePollInterval: .seconds(5),
        runtimeReadDeadline: .seconds(20),
        neverHandshakeGrace: .seconds(10),
        staleHandshake: .seconds(180),
        oneWayFlatDuration: .seconds(10),
        runtimeUnavailableDuration: .seconds(20),
        pathQuietPeriod: .seconds(10),
        pathSettlingCap: .seconds(30),
        recoveryVerificationDuration: .seconds(10),
        recoveryOperationDeadline: .seconds(20),
        healthyPollsToRecover: 2,
        persistenceHeartbeat: .seconds(15),
        snapshotFreshness: .seconds(30),
        snapshotFutureTolerance: .seconds(5),
        notificationOperationDeadline: .seconds(10),
        notificationInitialRetryDelay: .seconds(5),
        notificationMaximumRetryDelay: .seconds(60)
    )
}

extension Duration {
    public var gatewayTimeInterval: TimeInterval {
        let components = components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
