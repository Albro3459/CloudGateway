import Foundation
import Testing
@testable import CloudGatewayMacCLI

@MainActor
@Test func doctorSetupFailurePrecedesRequiredOnlineFailure() async throws {
    let doctor = CloudGatewayMacCLIDoctor(probes: [
        .init(name: "https", requirement: .online) { .init(name: "https", status: .fail, evidence: "HTTP 503") },
        .init(name: "app", requirement: .setup) { .init(name: "app", status: .fail, evidence: "App missing") },
        .init(name: "optional", requirement: .optional) { .init(name: "optional", status: .unknown, evidence: "Unsupported") }
    ])
    guard case .failure(let error) = await doctor.execute(timeout: .seconds(30)) else {
        Issue.record("Doctor must fail for required setup"); return
    }
    #expect(error.code.exitCode == 4)
    guard case .doctor(let report) = error.data else { Issue.record("Missing partial evidence"); return }
    #expect(report.checks.count == 3)
}

@MainActor
@Test func doctorOptionalWarningsAndUnknownsSucceed() async throws {
    let doctor = CloudGatewayMacCLIDoctor(probes: [
        .init(name: "credentials", requirement: .optional) { .init(name: "credentials", status: .unknown, evidence: "Uninitialized") },
        .init(name: "path", requirement: .optional) { .init(name: "path", status: .warning, evidence: "Use explicit path") }
    ])
    guard case .success(.doctor(let report)) = await doctor.execute(timeout: .seconds(30)) else {
        Issue.record("Optional evidence must not fail doctor"); return
    }
    #expect(!report.timedOut)
    #expect(report.render().contains("[unknown] credentials"))
    let record = CloudGatewayMacCLIRecord(type: .result, command: "doctor", data: .doctor(report))
    let json = try #require(try JSONSerialization.jsonObject(with: Data(record.line().utf8)) as? [String: Any])
    let data = try #require(json["data"] as? [String: Any])
    let checks = try #require(data["checks"] as? [[String: Any]])
    #expect(checks[0]["suggestion"] is NSNull)
}

@MainActor
@Test func doctorOverallDeadlinePreservesCompletedLocalChecks() async {
    let clock = CLITestClock()
    var laterProbeRan = false
    let doctor = CloudGatewayMacCLIDoctor(probes: [
        .init(name: "local", requirement: .setup) {
            try? await clock.clock.sleep(.seconds(2))
            return .init(name: "local", status: .pass, evidence: "Present")
        },
        .init(name: "network", requirement: .online) {
            laterProbeRan = true
            return .init(name: "network", status: .pass, evidence: "Reachable")
        }
    ], clock: clock.clock)
    guard case .failure(let error) = await doctor.execute(timeout: .seconds(1)),
          case .doctor(let report) = error.data else { Issue.record("Missing timeout report"); return }
    #expect(error.code.exitCode == 8)
    #expect(report.timedOut)
    #expect(report.checks.map(\.name) == ["local"])
    #expect(!laterProbeRan)
}

@MainActor
@Test func doctorHungProbeCancelsAndKeepsLocalEvidence() async {
    let clock = CLITestClock()
    var wasCancelled = false
    let doctor = CloudGatewayMacCLIDoctor(probes: [
        .init(name: "local", requirement: .setup) { .init(name: "local", status: .pass, evidence: "Present") },
        .init(name: "controller", requirement: .setup) {
            clock.expire()
            do { try await cliSuspendUntilCancelled() } catch { wasCancelled = true }
            return .init(name: "controller", status: .unknown, evidence: "Cancelled")
        }
    ], clock: clock.clock)
    guard case .failure(let error) = await doctor.execute(timeout: .seconds(30)),
          case .doctor(let report) = error.data else { Issue.record("Missing bounded report"); return }
    #expect(error.code.exitCode == 4)
    #expect(report.checks.count == 2)
    for _ in 0..<100 where !wasCancelled { await Task.yield() }
    #expect(wasCancelled)
}

@MainActor
@Test func doctorRequiredOnlineFailureReturnsSix() async {
    let doctor = CloudGatewayMacCLIDoctor(probes: [
        .init(name: "https", requirement: .online) { .init(name: "https", status: .fail, evidence: "HTTP 500") }
    ])
    guard case .failure(let error) = await doctor.execute(timeout: .seconds(30)) else { Issue.record("Expected online failure"); return }
    #expect(error.code.exitCode == 6)
}

@MainActor
@Test func doctorDeadlineCanFinishWhileBlockingValidationRemainsOnWorker() async {
    let clock = CLITestClock()
    let release = DispatchSemaphore(value: 0)
    let doctor = CloudGatewayMacCLIDoctor(probes: [
        .init(name: "local", requirement: .setup) { .init(name: "local", status: .pass, evidence: "Present") },
        .init(name: "identity", requirement: .setup) {
            await Task.detached { () -> CloudGatewayMacCLIDoctorReport.Check in
                clock.expire()
                waitForHeldValidation(release)
                return .init(name: "identity", status: .pass, evidence: "Validated")
            }.value
        }
    ], clock: clock.clock)
    defer { release.signal() }
    guard case .failure(let error) = await doctor.execute(timeout: .seconds(30)),
          case .doctor(let report) = error.data else { Issue.record("Blocking validation bypassed deadline"); return }
    #expect(error.code.exitCode == 4)
    #expect(report.checks.count == 2)
}

private func waitForHeldValidation(_ release: DispatchSemaphore) {
    release.wait()
}
