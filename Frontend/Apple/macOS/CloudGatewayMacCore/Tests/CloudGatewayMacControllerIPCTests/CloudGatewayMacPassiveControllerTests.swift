import Foundation
import CloudGatewayMacIPC
import Testing
@testable import CloudGatewayMacControllerIPC
@testable import CloudGatewayMacCore

@MainActor
@Test func coldDoctorDoesNotInitializeRetainedDeniedRuntime() async throws {
    var restorations = 0
    var signOuts = 0
    var inventoryReads = 0
    var cacheInvalidations = 0
    let runtime = CloudGatewayMacPassiveRuntime {
        restorations += 1
        // Model the retained denied session's normal restoration effects
        signOuts += 1
        inventoryReads += 1
        cacheInvalidations += 1
        return true
    }
    var readinessReads = 0
    let effects = CloudGatewayMacControllerEffects(
        snapshot: { _, _ in controllerBoundaryState() }, hasPendingWork: { false },
        perform: { _, complete in complete(.completed(warning: nil)); return true },
        refresh: { .refreshed }, prepareClient: { .init(regions: []) { _, _, _ in false } },
        setSetupState: { _ in }, hasAnyActiveTunnel: { readinessReads += 1; return false },
        installedIdentity: { controllerBoundaryBuild }, extensionIdentity: { controllerBoundaryBuild },
        ping: { _ in readinessReads += 1; return nil },
        initializeRuntime: { _ = runtime.require() }, isRuntimeInitialized: { runtime.initialized != nil },
        diagnostics: { .init(runtimeInitialized: runtime.initialized != nil) }
    )
    let controller = try CloudGatewayMacControllerOrchestrator(identity: controllerBoundaryBuild, effects: effects,
        requests: .init(data: nil, persist: { _ in }), extensionUpdates: .init(bootSession: { "boot" }, persist: { _ in }))
    await controller.tick()
    _ = await controller.handle(controllerBoundaryRequest(.lifecycle))
    let reply = await controller.handle(controllerBoundaryRequest(.diagnostics))
    #expect(reply.diagnostics?.runtimeInitialized == false)
    #expect(reply.diagnostics?.credentials == nil)
    #expect(restorations == 0 && signOuts == 0 && inventoryReads == 0 && cacheInvalidations == 0)
    #expect(readinessReads == 0)
    _ = await controller.handle(controllerBoundaryRequest(.snapshot))
    _ = await controller.handle(controllerBoundaryRequest(.snapshot))
    #expect(restorations == 1 && signOuts == 1 && inventoryReads == 1 && cacheInvalidations == 1)
}

@Test func diagnosticEnvelopeRejectsColdCredentialClaimsAndUnexpectedFields() throws {
    let invalid = CloudGatewayMacControllerDiagnostics(runtimeInitialized: false, access: .online, credentials: .available)
    #expect(throws: CloudGatewayMacControllerFailure.invalidRequest) { try invalid.validate() }
    let reply = CloudGatewayMacControllerReply(diagnostics: .init(runtimeInitialized: false))
    let data = CloudGatewayMacControllerProtocol.encodeReply(reply, appVersion: "1", appBuild: "2", instanceId: UUID(), action: .snapshot)
    let decoded = try CloudGatewayMacControllerProtocol.decodeReply(data, appVersion: "1", appBuild: "2", action: .snapshot)
    #expect(decoded.error == .invalidRequest)
}

@Test func diagnosticExtensionEvidenceSeparatesMismatchFromNoReply() {
    let target = controllerBoundaryBuild
    let match = CloudGatewayMacExtensionVersion(infoDictionary: ["CFBundleVersion": target.build,
        "CFBundleShortVersionString": target.version], codeHash: target.codeHash)
    #expect(CloudGatewayMacControllerDiagnostics.extensionReadiness(installed: target, observed: match) == .ready)
    let mismatch = CloudGatewayMacExtensionVersion(infoDictionary: ["CFBundleVersion": "old",
        "CFBundleShortVersionString": target.version], codeHash: target.codeHash)
    #expect(CloudGatewayMacControllerDiagnostics.extensionReadiness(installed: target, observed: mismatch) == .incompatible)
    let resigned = CloudGatewayMacExtensionVersion(infoDictionary: ["CFBundleVersion": target.build,
        "CFBundleShortVersionString": target.version], codeHash: String(repeating: "e", count: 64))
    #expect(CloudGatewayMacControllerDiagnostics.extensionReadiness(installed: target, observed: resigned) == .replacementBlocked)
    #expect(CloudGatewayMacControllerDiagnostics.extensionReadiness(installed: target, observed: nil) == .enabled)
}

@Test func inventoryFailureEvidenceSurvivesDiagnosticSetupMapping() throws {
    let failure = CloudGatewayMacInventoryDiagnostic(stage: .regions, source: .deadline)
    let evidence = CloudGatewayMacControllerDiagnostics(runtimeInitialized: true, inventoryFailure: failure)
    #expect(evidence.withSetupState(.ready).inventoryFailure == failure)
    let encoded = try JSONEncoder().encode(evidence)
    #expect(try JSONDecoder().decode(CloudGatewayMacControllerDiagnostics.self, from: encoded) == evidence)
    #expect(throws: CloudGatewayMacControllerFailure.invalidRequest) {
        try CloudGatewayMacControllerDiagnostics(runtimeInitialized: false, inventoryFailure: failure).validate()
    }
}

@MainActor
@Test func firstNormalCommandStartsReadinessWhileLifecycleAndDoctorStayPassive() async throws {
    var initialized = false
    var setup = CloudGatewayMacSetupState.required
    var release: (() -> Void)?
    let effects = CloudGatewayMacControllerEffects(
        snapshot: { state, _ in controllerBoundaryState(setup: state) }, hasPendingWork: { false },
        perform: { _, _ in false }, refresh: { .refreshed },
        prepareClient: { .init(regions: []) { _, _, _ in false } },
        setSetupState: { setup = $0 }, hasAnyActiveTunnel: { false },
        installedIdentity: { controllerBoundaryBuild }, extensionIdentity: { controllerBoundaryBuild },
        ping: { target in
            await withCheckedContinuation { continuation in
                release = {
                    continuation.resume(returning: .init(infoDictionary: ["CFBundleVersion": target.build,
                        "CFBundleShortVersionString": target.version], codeHash: target.codeHash))
                }
            }
        }, initializeRuntime: { initialized = true }, isRuntimeInitialized: { initialized }
    )
    let controller = try CloudGatewayMacControllerOrchestrator(identity: controllerBoundaryBuild, effects: effects,
        requests: .init(data: nil, persist: { _ in }), extensionUpdates: .init(bootSession: { "boot" }, persist: { _ in }))
    await controller.tick()
    _ = await controller.handle(controllerBoundaryRequest(.lifecycle))
    _ = await controller.handle(controllerBoundaryRequest(.diagnostics))
    #expect(!initialized && release == nil)
    let first = await controller.handle(controllerBoundaryRequest(.snapshot))
    #expect(first.state?.setup == .checkingConnection)
    #expect(initialized)
    try #require(await controllerBoundaryEventually { release != nil })
    release?()
    try #require(await controllerBoundaryEventually { setup == .ready })
    let ready = await controller.handle(controllerBoundaryRequest(.snapshot))
    #expect(ready.state?.setup == .ready)
}

@MainActor
@Test func heldDiagnosticValidatorLeavesStatusAndConfirmedStopResponsive() async throws {
    let release = DispatchSemaphore(value: 0)
    let started = AsyncStream<Void>.makeStream()
    defer { release.signal(); started.continuation.finish() }
    let effects = CloudGatewayMacControllerEffects(
        snapshot: { _, _ in controllerBoundaryState() }, hasPendingWork: { false },
        perform: { _, complete in complete(.completed(warning: nil)); return true },
        refresh: { .refreshed }, prepareClient: { .init(regions: []) { _, _, _ in false } },
        setSetupState: { _ in }, hasAnyActiveTunnel: { false },
        installedIdentity: { controllerBoundaryBuild }, extensionIdentity: { controllerBoundaryBuild },
        ping: { _ in nil }, diagnostics: {
            _ = try? await CloudGatewayMacInventoryRequest.perform(timeout: .seconds(1)) {
                await Task.detached { () -> Bool in
                    started.continuation.yield(())
                    waitForHeldValidation(release)
                    return true
                }.value
            }
            return .init(runtimeInitialized: false)
        }
    )
    let controller = try CloudGatewayMacControllerOrchestrator(identity: controllerBoundaryBuild, effects: effects,
        requests: .init(data: nil, persist: { _ in }), extensionUpdates: .init(bootSession: { "boot" }, persist: { _ in }))
    await controller.tick()
    let diagnostic = Task { await controller.handle(controllerBoundaryRequest(.diagnostics)) }
    for await _ in started.stream { break }
    let status = await controller.handle(controllerBoundaryRequest(.status))
    #expect(status.status != nil)
    let id = UUID()
    let stop = await controller.handle(controllerBoundaryRequest(.turnOff, id: id))
    #expect(stop.operation?.state == .accepted)
    let confirmed = await controller.handle(controllerBoundaryRequest(.confirmOperation, contextId: id))
    #expect(confirmed.operation?.state == .completed)
    #expect(await diagnostic.value.diagnostics?.runtimeInitialized == false)
}

private func waitForHeldValidation(_ release: DispatchSemaphore) {
    release.wait()
}

@MainActor
@Test func coldLifecycleWaitsForSharedInitialInstallationObservation() async throws {
    let entered = AsyncStream<Void>.makeStream()
    defer { entered.continuation.finish() }
    var release: CheckedContinuation<CloudGatewayMacBuildIdentity?, Never>?
    var reads = 0
    var initializations = 0
    let effects = CloudGatewayMacControllerEffects(
        snapshot: { _, _ in controllerBoundaryState() }, hasPendingWork: { false }, perform: { _, _ in false },
        refresh: { .refreshed }, prepareClient: { .init(regions: []) { _, _, _ in false } },
        setSetupState: { _ in }, hasAnyActiveTunnel: { false },
        installedIdentity: {
            reads += 1
            return await withCheckedContinuation { release = $0; entered.continuation.yield(()) }
        }, extensionIdentity: { controllerBoundaryBuild }, ping: { _ in nil },
        initializeRuntime: { initializations += 1 }, isRuntimeInitialized: { false }
    )
    let controller = try CloudGatewayMacControllerOrchestrator(identity: controllerBoundaryBuild, effects: effects,
        requests: .init(data: nil, persist: { _ in }), extensionUpdates: .init(bootSession: { "boot" }, persist: { _ in }))
    var lifecycleFinished = false
    let lifecycle = Task {
        let reply = await controller.handle(controllerBoundaryRequest(.lifecycle))
        lifecycleFinished = true
        return reply
    }
    for await _ in entered.stream { break }
    let concurrent = Task { await controller.handle(controllerBoundaryRequest(.lifecycle)) }
    let diagnostic = await controller.handle(controllerBoundaryRequest(.diagnostics))
    #expect(diagnostic.diagnostics?.runtimeInitialized == false)
    #expect(!lifecycleFinished)
    let continuation = try #require(release)
    continuation.resume(returning: controllerBoundaryBuild)
    let reply = await lifecycle.value
    #expect(reply.lifecycle?.state == .current)
    #expect(reply.lifecycle?.installed == controllerBoundaryBuild)
    #expect(await concurrent.value.lifecycle?.state == .current)
    #expect(reads == 1 && initializations == 0)
}

@MainActor
@Test func stalledInitialObservationBoundsReadersAcrossRetriesAndFencesLateIdentity() async throws {
    let clock = InstallationObservationClock()
    var now = Date(timeIntervalSince1970: 1000)
    var reads = 0
    var initializations = 0
    var late: CheckedContinuation<CloudGatewayMacBuildIdentity?, Never>?
    var lateFinished = false
    defer { late?.resume(returning: nil); clock.expire() }
    let effects = CloudGatewayMacControllerEffects(
        snapshot: { _, _ in controllerBoundaryState() }, hasPendingWork: { false },
        perform: { _, complete in complete(.completed(warning: nil)); return true },
        refresh: { .refreshed }, prepareClient: { .init(regions: []) { _, _, _ in false } },
        setSetupState: { _ in }, hasAnyActiveTunnel: { false },
        installedIdentity: {
            reads += 1
            if reads == 1 {
                let identity = await withCheckedContinuation { late = $0 }
                lateFinished = true
                return identity
            }
            return controllerBoundaryBuild
        }, installationTimer: { _ in try await clock.wait() },
        extensionIdentity: { controllerBoundaryBuild }, ping: { _ in nil },
        initializeRuntime: { initializations += 1 }, isRuntimeInitialized: { false },
        monotonicNow: { .seconds(now.timeIntervalSince1970) }, now: { now }
    )
    let controller = try CloudGatewayMacControllerOrchestrator(identity: controllerBoundaryBuild, effects: effects,
        requests: .init(data: nil, persist: { _ in }), extensionUpdates: .init(bootSession: { "boot" }, persist: { _ in }))
    var entered = 0
    let callers = (0..<64).map { _ in Task {
        entered += 1
        return await controller.handle(controllerBoundaryRequest(.lifecycle))
    } }
    try #require(await controllerBoundaryEventually { entered == 64 && late != nil && !clock.timers.isEmpty })
    callers.forEach { $0.cancel() }
    clock.expire()
    for caller in callers { #expect(await caller.value.error == .timeout) }
    #expect(reads == 1)
    for _ in 0..<8 {
        let retries = (0..<64).map { _ in Task {
            await controller.handle(controllerBoundaryRequest(.lifecycle))
        } }
        for retry in retries { #expect(await retry.value.error == .timeout) }
        await controller.tick()
        #expect(reads == 1 && clock.timers.isEmpty)
    }
    let diagnostic = await controller.handle(controllerBoundaryRequest(.diagnostics))
    #expect(diagnostic.diagnostics?.runtimeInitialized == false && initializations == 0)
    now = now.addingTimeInterval(901)
    #expect(controller.canExit)
    let status = await controller.handle(controllerBoundaryRequest(.status))
    #expect(status.status != nil)
    let id = UUID()
    _ = await controller.handle(controllerBoundaryRequest(.turnOff, id: id))
    let stop = await controller.handle(controllerBoundaryRequest(.confirmOperation, contextId: id))
    #expect(stop.operation?.state == .completed)
    let continuation = try #require(late)
    late = nil
    continuation.resume(returning: controllerBoundaryReplacement)
    try #require(await controllerBoundaryEventually { lateFinished })
    var retry: CloudGatewayMacControllerReply?
    for _ in 0..<1_000 {
        let reply = await controller.handle(controllerBoundaryRequest(.lifecycle))
        if reply.error != .timeout { retry = reply; break }
        await Task.yield()
    }
    let recovered = try #require(retry)
    #expect(recovered.lifecycle?.state == .current && recovered.lifecycle?.installed == controllerBoundaryBuild)
    let afterLateReply = await controller.handle(controllerBoundaryRequest(.lifecycle))
    #expect(afterLateReply.lifecycle?.state == .current && afterLateReply.lifecycle?.installed == controllerBoundaryBuild)
    #expect(reads == 2)
    try #require(await controllerBoundaryEventually { clock.timers.isEmpty })
}

@MainActor
private final class InstallationObservationClock {
    var timers: [UUID: CheckedContinuation<Void, any Error>] = [:]

    func wait() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { timers[id] = continuation }
            }
        } onCancel: {
            Task { @MainActor in self.timers.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
        }
    }

    func expire() {
        let waiting = Array(timers.values)
        timers = [:]
        waiting.forEach { $0.resume() }
    }
}
