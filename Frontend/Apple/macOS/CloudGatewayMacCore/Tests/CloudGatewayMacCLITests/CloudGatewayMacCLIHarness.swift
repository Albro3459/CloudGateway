import CloudGatewayAppCore
import CloudGatewayKit
import CloudGatewayMacIPC
import Foundation
import Synchronization
import Testing
@testable import CloudGatewayMacCLI
@testable import CloudGatewayMacControllerIPC
@testable import CloudGatewayMacCore

let cliBuild = CloudGatewayMacBuildIdentity(version: "1.2.0", build: "7", codeHash: String(repeating: "c", count: 64))
let cliObservedAt = Date(timeIntervalSince1970: 1_800_000_000)

func cliClient(_ identifier: String, regionName: String, order: Int = 0, name: String, owner: String? = nil,
               ip: String? = "10.0.0.2", installed: Bool = true, source: CloudGatewayMacInventorySource = .cloud,
               eligibility: CloudGatewayMacClientEligibility = .eligible, cloudState: CloudGatewayClientStatus = .active,
               status: CloudGatewayTunnelStatus? = .disconnected) -> CloudGatewayMacClientMetadata {
    .init(identifier: identifier, regionId: String(identifier.split(separator: "/")[1]), regionName: regionName,
          regionOrder: order, clientName: name, ownerLabel: owner, internalIp: ip, cloudState: cloudState,
          eligibility: eligibility, isInstalled: installed, source: source,
          readAt: Date(timeIntervalSince1970: 0), updatedAt: nil, status: status)
}

func cliState(account: String? = "uid1", retained: Bool = true, restoring: Bool = false,
              access: CloudGatewayMacAccessState = .online, inventory: CloudGatewayMacInventoryFreshness = .current,
              clients: [CloudGatewayMacClientMetadata] = [], profiles: [CloudGatewayMacObservedProfile] = [],
              isObserved: Bool = true, observedAt: Date? = cliObservedAt, selected: String? = nil,
              browser: CloudGatewayMacBrowserAuthState? = nil,
              setup: CloudGatewayMacSetupState = .ready) -> CloudGatewayMacControllerState {
    let snapshot = CloudGatewayMacControllerSnapshot(
        domain: .init(accountId: account, hasRetainedSession: retained, accessAuthorized: account != nil,
                      access: access, credentials: retained ? .available : .unknown, inventoryFreshness: inventory,
                      installedIdentifiers: clients.filter(\.isInstalled).map(\.identifier), observedProfiles: profiles,
                      observationIsFresh: isObserved, profilesObservedAt: observedAt, commandInFlight: false,
                      clients: clients),
        lastSelectedIdentifier: selected,
        browserState: browser ?? account.map { .signedIn(AuthenticatedUser(uid: $0, email: nil)) } ?? .signedOut,
        isRestoringSession: restoring, isAuthSettling: false, canCreateClient: false, errorMessage: nil
    )
    return .init(snapshot: snapshot, setupState: setup, canUpdateExtension: false)
}

func cliSuspendUntilCancelled() async throws {
    let (stream, continuation) = AsyncStream<Never>.makeStream()
    for await _ in stream {}
    continuation.finish()
    throw CancellationError()
}

final class CLITestClock: Sendable {
    private struct State {
        var elapsed = Duration.zero
        var isExpired = false
        var timers: [UUID: CheckedContinuation<Void, any Error>] = [:]
    }

    private let state = Mutex(State())

    var now: Duration { state.withLock { $0.elapsed } }

    // Fires every caller deadline timer, now and later
    func expire() {
        let timers = state.withLock { state in
            state.isExpired = true
            defer { state.timers = [:] }
            return Array(state.timers.values)
        }
        timers.forEach { $0.resume() }
    }

    var clock: CloudGatewayMacCLIClock {
        .init(now: { self.now }, sleep: { duration in self.state.withLock { $0.elapsed += duration } }, timer: { _ in
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let result: Result<Void, any Error>? = self.state.withLock { state in
                        if state.isExpired { return .success(()) }
                        if Task.isCancelled { return .failure(CancellationError()) }
                        state.timers[id] = continuation
                        return nil
                    }
                    if let result { continuation.resume(with: result) }
                }
            } onCancel: {
                self.state.withLock { $0.timers.removeValue(forKey: id) }?.resume(throwing: CancellationError())
            }
        })
    }
}

@MainActor
final class CLIHarness {
    var instanceId = UUID()
    var lifecycle = CloudGatewayMacControllerLifecycle.State.current
    var installed: CloudGatewayMacBuildIdentity? = cliBuild
    var unavailableHandshakes = 0
    var bootstraps = 0
    var connects = 0
    var isUntrusted = false
    var holdsClientCreation = false
    var states: [CloudGatewayMacControllerState] = []
    var status = CloudGatewayMacControllerStatus(hasActiveTunnel: false, needsStop: false, observationAvailable: true)
    var operation: CloudGatewayMacControllerOperation?
    var outcome: CloudGatewayMacCommandOutcome?
    var hungActions: Set<CloudGatewayMacControllerRequest.Action> = []
    var onRequest: ((CloudGatewayMacControllerRequest) async throws -> CloudGatewayMacControllerReply?)?
    var onBootstrap: (() async throws -> Void)?
    var actions: [CloudGatewayMacControllerRequest.Action] = []
    var output = ""
    var diagnostics = ""
    var failsOutput = false
    var terminal = CloudGatewayMacCLITerminal(isOutputTerminal: false, variables: [:])
    var version = (short: "1.2.0", build: "7")
    let clock: CLITestClock

    init(_ states: CloudGatewayMacControllerState..., clock: CLITestClock = CLITestClock()) {
        self.states = states
        self.clock = clock
    }

    func run(_ arguments: String...) async -> Int32 {
        await run(arguments)
    }

    func run(_ arguments: [String]) async -> Int32 {
        let cli = CloudGatewayMacCLI(version: version.short, build: version.build, terminal: terminal, clock: clock.clock, output: {
            if self.failsOutput { throw CocoaError(.fileWriteUnknown) }
            self.output += $0
        }, diagnostics: { self.diagnostics += $0 }, connect: {
            self.connects += 1
            if self.holdsClientCreation {
                self.clock.expire()
                try await cliSuspendUntilCancelled()
            }
            if self.isUntrusted { throw CocoaError(.fileReadCorruptFile) }
            return CloudGatewayMacFrontendClient(identity: cliBuild, transport: { try await self.send($0) },
                                                 bootstrap: {
                                                     self.bootstraps += 1
                                                     try await self.onBootstrap?()
                                                 }, sleep: { _ in })
        })
        return await cli.run(arguments)
    }

    var json: [String: Any]? {
        guard let line = output.split(separator: "\n").first else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    }

    private func send(_ request: CloudGatewayMacControllerRequest) async throws -> CloudGatewayMacControllerReply {
        actions.append(request.action)
        if hungActions.contains(request.action) {
            clock.expire()
            try await cliSuspendUntilCancelled()
        }
        var reply: CloudGatewayMacControllerReply
        if var custom = try await onRequest?(request) {
            custom.instanceId = instanceId
            return custom
        }
        switch request.action {
        case .lifecycle:
            if unavailableHandshakes > 0 {
                unavailableHandshakes -= 1
                throw CloudGatewayMacControllerFailure.unavailable
            }
            reply = .init(lifecycle: .init(running: cliBuild, installed: installed, state: lifecycle))
        case .snapshot:
            let state = states.count > 1 ? states.removeFirst() : try #require(states.first)
            reply = .init(state: state, operation: operation, outcome: outcome)
        case .status:
            reply = .init(status: status, operation: operation, outcome: outcome)
        case .operation:
            let id = try #require(request.contextId)
            let isRetained = operation?.id == id
            reply = .init(status: status, operation: isRetained ? operation : .init(id: id, state: .unknown),
                          outcome: isRetained ? outcome : nil)
        default:
            Issue.record("Unexpected controller request \(request.action)")
            throw CloudGatewayMacControllerFailure.invalidRequest
        }
        reply.instanceId = instanceId
        return reply
    }
}
