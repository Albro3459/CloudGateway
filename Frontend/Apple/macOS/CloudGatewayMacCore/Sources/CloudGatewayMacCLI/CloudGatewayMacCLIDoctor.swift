import Foundation

public struct CloudGatewayMacCLIDoctorReport: Encodable, Sendable {
    public struct Check: Encodable, Sendable {
        public enum Status: String, Encodable, Sendable {
            case pass, warning, fail, unknown
        }

        public let name: String
        public let status: Status
        public let evidence: String
        @CloudGatewayMacCLINullable var suggestion: String?

        public init(name: String, status: Status, evidence: String, suggestion: String? = nil) {
            self.name = CloudGatewayMacCLIText.sanitize(name)
            self.status = status
            self.evidence = CloudGatewayMacCLIText.sanitize(evidence)
            self.suggestion = suggestion.map(CloudGatewayMacCLIText.sanitize)
        }
    }

    public let checks: [Check]
    public let timedOut: Bool

    func render() -> String {
        checks.map {
            "[\($0.status.rawValue)] \($0.name): \($0.evidence)\n"
                + ($0.suggestion.map { "  \($0)\n" } ?? "")
        }.joined()
    }
}

@MainActor
public struct CloudGatewayMacCLIDoctor {
    public struct Probe: Sendable {
        public enum Requirement: Sendable {
            case setup, online, optional
        }

        let name: String
        let requirement: Requirement
        let timeout: Duration
        let run: @MainActor @Sendable () async -> CloudGatewayMacCLIDoctorReport.Check

        public init(name: String, requirement: Requirement, timeout: Duration = .seconds(5),
                    run: @escaping @MainActor @Sendable () async -> CloudGatewayMacCLIDoctorReport.Check) {
            self.name = name
            self.requirement = requirement
            self.timeout = timeout
            self.run = run
        }
    }

    private let probes: [Probe]
    private let clock: CloudGatewayMacCLIClock

    public init(probes: [Probe]) {
        self.init(probes: probes, clock: .continuous)
    }

    init(probes: [Probe], clock: CloudGatewayMacCLIClock) {
        self.probes = probes
        self.clock = clock
    }

    func execute(timeout: Duration) async -> Result<CloudGatewayMacCLIData, CloudGatewayMacCLIError> {
        let deadline = clock.now() + timeout
        var checks: [CloudGatewayMacCLIDoctorReport.Check] = []
        var setupFailed = false
        var onlineFailed = false
        var timedOut = false
        for probe in probes {
            let remaining = deadline - clock.now()
            guard remaining > .zero else { timedOut = true; break }
            let check = await bounded(probe, timeout: min(probe.timeout, remaining))
            checks.append(check)
            if check.status == .fail {
                if probe.requirement == .setup { setupFailed = true }
                if probe.requirement == .online { onlineFailed = true }
            }
            if Task.isCancelled { break }
            if clock.now() >= deadline { timedOut = true; break }
        }
        let data = CloudGatewayMacCLIData.doctor(.init(checks: checks, timedOut: timedOut))
        if Task.isCancelled { return .failure(.init(.interrupted, data: data)) }
        if timedOut { return .failure(.init(.timeout, data: data)) }
        if setupFailed { return .failure(.init(.setupRequired, data: data)) }
        if onlineFailed { return .failure(.init(.networkUnavailable, data: data)) }
        return .success(data)
    }

    private func bounded(_ probe: Probe, timeout: Duration) async -> CloudGatewayMacCLIDoctorReport.Check {
        let race = DoctorProbeRace()
        let work = Task { race.finish(await probe.run()) }
        let timer = Task {
            do { try await clock.timer(timeout) } catch { return }
            race.finish(.init(name: probe.name, status: probe.requirement == .optional ? .unknown : .fail,
                              evidence: "The check did not finish before its deadline",
                              suggestion: "Run doctor again after checking this Mac's setup and network"))
        }
        defer { work.cancel(); timer.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { race.start($0) }
        } onCancel: {
            Task { @MainActor in
                race.finish(.init(name: probe.name, status: .unknown, evidence: "The check was interrupted"))
            }
        }
    }
}

@MainActor
private final class DoctorProbeRace {
    private var result: CloudGatewayMacCLIDoctorReport.Check?
    private var continuation: CheckedContinuation<CloudGatewayMacCLIDoctorReport.Check, Never>?

    func start(_ continuation: CheckedContinuation<CloudGatewayMacCLIDoctorReport.Check, Never>) {
        if let result { continuation.resume(returning: result) }
        else { self.continuation = continuation }
    }

    func finish(_ result: CloudGatewayMacCLIDoctorReport.Check) {
        guard self.result == nil else { return }
        self.result = result
        continuation?.resume(returning: result)
        continuation = nil
    }
}
