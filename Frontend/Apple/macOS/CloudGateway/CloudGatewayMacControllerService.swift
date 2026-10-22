import CloudGatewayMacControllerIPC
import CloudGatewayMacCore
import CloudGatewayMacIPC
import CryptoKit
import Darwin
import Foundation

@MainActor
final class CloudGatewayMacControllerService {
    private struct Creation {
        let id: UUID
        let context: CloudGatewayMacClientCreationContext
        let expires: ContinuousClock.Instant
    }

    private struct Receipt: Codable {
        let digest: String
        let accepted: Bool?
        let expires: Date
    }

    private struct ExtensionUpdate: Codable {
        let id: UUID
        let target: CloudGatewayMacBuildIdentity
        let bootSession: String
        var phase: String
        var deadline: Date?
    }

    private struct StoredState: Codable {
        var receipts: [UUID: Receipt]
        var extensionUpdate: ExtensionUpdate?
        var finishedExtensionUpdates: [UUID: Date]
    }

    // periphery:ignore - Holding the lock prevents a second Firebase owner for the service lifetime
    private let ownership: CloudGatewayMacControllerOwnership
    private let runtime: CloudGatewayMacControllerRuntime
    private let teamIdentifier: String
    private var server: CloudGatewayMacControllerServer!
    private var setupState = CloudGatewayMacSetupState.required
    private var readinessTask: Task<Void, Never>?
    private let clock = ContinuousClock()
    private var lastActivity = ContinuousClock().now
    private var activeRequests = 0
    private var creation: Creation?
    private var receipts: [UUID: Receipt] = [:]
    private var update: CloudGatewayMacUpdateLifecycle
    private var checkingInstallation = false
    private var extensionIsIdle = false
    private var extensionUpdate: ExtensionUpdate?
    private var finishedExtensionUpdates: [UUID: Date] = [:]
    private var extensionEpoch: UInt64 = 0
    private static let installedURL = URL(fileURLWithPath: "/Applications/CloudGateway.app")

    init(identity: CloudGatewayMacBuildIdentity) throws {
        update = CloudGatewayMacUpdateLifecycle(running: identity)
        ownership = try CloudGatewayMacControllerOwnership(directory: CloudGatewayMacControllerRuntime.directory)
        teamIdentifier = Bundle.main.object(forInfoDictionaryKey: "CloudGatewayTeamIdentifier") as? String ?? ""
        if let data = try CloudGatewayMacControllerUpdateStorage.load(directory: CloudGatewayMacControllerRuntime.directory) {
            let state = try JSONDecoder().decode(StoredState.self, from: data)
            receipts = state.receipts
            extensionUpdate = state.extensionUpdate
            finishedExtensionUpdates = state.finishedExtensionUpdates.filter { $0.value > Date() }
            if extensionUpdate?.phase == "activating", extensionUpdate?.bootSession == Self.bootSession() {
                extensionUpdate?.phase = "restart"
            }
            guard receipts.count <= 64 else { throw CloudGatewayMacControllerFailure.invalidRequest }
        }
        runtime = CloudGatewayMacControllerRuntime()
        server = try CloudGatewayMacControllerServer(
            teamIdentifier: teamIdentifier,
            appVersion: identity.version,
            appBuild: identity.build,
            buildIdentity: identity
        ) { [weak self] request in
            guard let self else { return CloudGatewayMacControllerReply(error: .unavailable) }
            return await handle(request)
        }
    }

    func run() {
        runtime.controller.start()
        server.resume()
        Task { [weak self] in
            var hadPendingWork = false
            while !Task.isCancelled {
                guard let self else { return }
                await checkInstallation()
                if update.canExit(hasPendingWork: runtime.controller.hasPendingWork || readinessTask != nil,
                                  activeRequests: activeRequests), server.invalidateIfIdle() {
                    runtime.shutdown()
                    exit(EXIT_SUCCESS)
                }
                let hasPendingWork = runtime.controller.hasPendingWork || activeRequests > 0
                if hasPendingWork || hadPendingWork {
                    lastActivity = clock.now
                } else if lastActivity.duration(to: clock.now) >= .seconds(60), readinessTask == nil,
                          extensionUpdate == nil, server.invalidateIfIdle() {
                    runtime.shutdown()
                    exit(EXIT_SUCCESS)
                }
                hadPendingWork = hasPendingWork
                if update.canAcceptMutations, readinessTask == nil { refreshReadiness() }
                do { try await Task.sleep(for: .seconds(5)) }
                catch { return }
            }
        }
    }

    private func reply(accepted: Bool? = nil, operationId: UUID? = nil) -> CloudGatewayMacControllerReply {
        CloudGatewayMacControllerReply(
            snapshot: CloudGatewayMacControllerView(snapshot: runtime.controller.snapshot(setupState: setupState),
                                                    setupState: setupState,
                                                    canUpdateExtension: extensionIsIdle && extensionUpdate == nil
                                                        && !runtime.controller.hasPendingWork && update.canAcceptMutations),
            accepted: accepted, operationId: operationId
        )
    }

    private func handle(_ request: CloudGatewayMacControllerRequest) async -> CloudGatewayMacControllerReply {
        activeRequests += 1
        if !update.isDraining { lastActivity = clock.now }
        defer { activeRequests -= 1; if !update.isDraining { lastActivity = clock.now } }
        if request.action == .lifecycle {
            return CloudGatewayMacControllerReply(lifecycle: .init(
                running: update.running, installed: update.installed,
                state: update.isDraining ? .draining : update.installed == nil ? .invalidInstallation : .current
            ))
        }
        let activationCallbacks: Set<CloudGatewayMacControllerRequest.Action> = [
            .extensionUpdateStarted, .extensionUpdateApproval, .extensionUpdateRestart, .extensionUpdateFinished, .extensionUpdateFailed
        ]
        guard update.canAcceptMutations || request.action == .snapshot || request.action == .turnOff
            || activationCallbacks.contains(request.action) else {
            return CloudGatewayMacControllerReply(error: .busy)
        }
        receipts = receipts.filter { $0.value.expires > Date() }
        if let receipt = receipts[request.id] {
            guard receipt.digest == digest(request) else { return CloudGatewayMacControllerReply(error: .invalidRequest) }
            guard let accepted = receipt.accepted else { return CloudGatewayMacControllerReply(error: .outcomeUnknown) }
            return accepted ? reply(accepted: true, operationId: request.id) : CloudGatewayMacControllerReply(error: .busy)
        }
        let mutations: Set<CloudGatewayMacControllerRequest.Action> = [
            .signIn, .cancelSignIn, .signOut, .connect, .turnOff, .createClient
        ]
        if mutations.contains(request.action), !reserve(request) {
            return CloudGatewayMacControllerReply(error: .unavailable)
        }
        let controller = runtime.controller
        switch request.action {
        case .lifecycle: return CloudGatewayMacControllerReply(error: .invalidRequest)
        case .prepareExtensionUpdate:
            return await prepareExtensionUpdate()
        case .extensionUpdateStarted, .extensionUpdateApproval, .extensionUpdateRestart, .extensionUpdateFinished, .extensionUpdateFailed:
            return finishExtensionUpdate(request)
        case .snapshot:
            return reply()
        case .menuWillOpen:
            controller.menuWillOpen()
            refreshReadiness()
            return reply()
        case .refresh:
            controller.refresh()
            refreshReadiness()
            return reply()
        case .signIn:
            let state = controller.snapshot(setupState: setupState)
            guard !state.isRestoringSession, !state.isAuthSettling else {
                return record(request, accepted: false)
            }
            controller.signIn()
        case .cancelSignIn:
            creation = nil
            controller.cancelSignIn()
        case .signOut:
            creation = nil
            controller.signOut()
        case .connect:
            guard let identifier = request.identifier else { return CloudGatewayMacControllerReply(error: .invalidRequest) }
            return record(request, accepted: controller.connectClient(identifier: identifier))
        case .turnOff:
            return record(request, accepted: controller.turnOff())
        case .prepareClient:
            guard let context = controller.clientCreationContext() else {
                return CloudGatewayMacControllerReply(error: .busy)
            }
            let id = UUID()
            let preparation = Creation(id: id, context: context, expires: clock.now.advanced(by: .seconds(300)))
            creation = preparation
            do {
                let regions = try await controller.loadCreateRegions(context: context)
                guard creation?.id == id, preparation.expires > clock.now else {
                    return CloudGatewayMacControllerReply(error: .rejected)
                }
                return CloudGatewayMacControllerReply(creation: .init(id: id, regions: regions))
            } catch {
                if creation?.id == id { creation = nil }
                return CloudGatewayMacControllerReply(error: .rejected)
            }
        case .createClient:
            guard let preparation = creation, preparation.id == request.contextId,
                  preparation.expires > clock.now,
                  let regionId = request.regionId, let clientName = request.clientName else {
                return CloudGatewayMacControllerReply(error: .rejected)
            }
            creation = nil
            return record(request, accepted: controller.createClient(
                regionId: regionId, clientName: clientName, context: preparation.context
            ))
        }
        return record(request, accepted: true)
    }

    private func reserve(_ request: CloudGatewayMacControllerRequest) -> Bool {
        guard receipts.count < 64 else { return false }
        receipts[request.id] = Receipt(digest: digest(request), accepted: nil, expires: Date().addingTimeInterval(600))
        do { try persistReceipts(); return true }
        catch { return false }
    }

    private func record(_ request: CloudGatewayMacControllerRequest, accepted: Bool) -> CloudGatewayMacControllerReply {
        receipts[request.id] = Receipt(digest: digest(request), accepted: accepted, expires: Date().addingTimeInterval(600))
        do { try persistReceipts() }
        catch { return CloudGatewayMacControllerReply(error: .outcomeUnknown) }
        return accepted ? reply(accepted: true, operationId: request.id) : CloudGatewayMacControllerReply(error: .busy)
    }

    private func persistReceipts() throws {
        try CloudGatewayMacControllerUpdateStorage.save(
            JSONEncoder().encode(StoredState(receipts: receipts, extensionUpdate: extensionUpdate,
                                             finishedExtensionUpdates: finishedExtensionUpdates)),
            directory: CloudGatewayMacControllerRuntime.directory
        )
    }

    private func digest(_ request: CloudGatewayMacControllerRequest) -> String {
        let content = [request.action.rawValue, request.identifier ?? "", request.regionId ?? "",
                       request.clientName ?? "", request.contextId?.uuidString ?? ""]
        return SHA256.hash(data: (try? JSONEncoder().encode(content)) ?? Data()).map { String(format: "%02x", $0) }.joined()
    }

    private func checkInstallation() async {
        guard !checkingInstallation else { return }
        checkingInstallation = true
        defer { checkingInstallation = false }
        let team = teamIdentifier
        let installedURL = Self.installedURL
        let installed = await Task.detached {
            try? CloudGatewayMacSignedBundle.installed(at: installedURL, teamIdentifier: team,
                                                       bundleIdentifier: CloudGatewayMacControllerProtocol.appBundleIdentifier)
        }.value
        update.observe(installed)
        if update.isDraining { creation = nil }
    }

    private func prepareExtensionUpdate() async -> CloudGatewayMacControllerReply {
        guard extensionUpdate == nil, !runtime.controller.hasPendingWork, readinessTask == nil else {
            return CloudGatewayMacControllerReply(error: .busy)
        }
        let previous = setupState
        let id = UUID()
        do {
            let expected = try bundledExtensionIdentity()
            extensionUpdate = ExtensionUpdate(id: id, target: expected, bootSession: Self.bootSession(),
                                              phase: "prepared", deadline: Date().addingTimeInterval(30))
            extensionEpoch &+= 1
            setSetupState(.activating)
            try persistReceipts()
            guard try await !runtime.hasAnyActiveTunnel(), update.canAcceptMutations,
                  extensionUpdate?.id == id, try bundledExtensionIdentity() == expected else {
                throw CloudGatewayMacControllerFailure.busy
            }
            return CloudGatewayMacControllerReply(accepted: true, operationId: id, extensionTarget: expected)
        } catch {
            if extensionUpdate?.id == id {
                extensionUpdate = nil
                extensionEpoch &+= 1
                try? persistReceipts()
                setSetupState(previous)
            }
            return CloudGatewayMacControllerReply(error: error as? CloudGatewayMacControllerFailure ?? .unavailable)
        }
    }

    private func finishExtensionUpdate(_ request: CloudGatewayMacControllerRequest) -> CloudGatewayMacControllerReply {
        finishedExtensionUpdates = finishedExtensionUpdates.filter { $0.value > Date() }
        if let id = request.contextId, finishedExtensionUpdates[id] != nil {
            do { try persistReceipts(); return reply(accepted: true) }
            catch { return CloudGatewayMacControllerReply(error: .unavailable) }
        }
        guard var pending = extensionUpdate, pending.id == request.contextId else {
            return CloudGatewayMacControllerReply(error: .rejected)
        }
        extensionEpoch &+= 1
        if pending.phase == "restart", request.action == .extensionUpdateApproval { return reply(accepted: true) }
        switch request.action {
        case .extensionUpdateStarted:
            if pending.phase != "prepared" { return reply(accepted: true) }
            guard pending.deadline.map({ $0 > Date() }) == true, update.canAcceptMutations else {
                return CloudGatewayMacControllerReply(error: .rejected)
            }
            pending.phase = "activating"
            pending.deadline = Date().addingTimeInterval(120)
            extensionUpdate = pending
            setSetupState(.activating)
        case .extensionUpdateApproval:
            pending.phase = "approval"
            extensionUpdate = pending
            setSetupState(.awaitingApproval)
        case .extensionUpdateRestart:
            pending.phase = "restart"
            extensionUpdate = pending
            setSetupState(.awaitingRestart)
        case .extensionUpdateFinished, .extensionUpdateFailed:
            extensionUpdate = nil
            if finishedExtensionUpdates.count >= 16, let oldest = finishedExtensionUpdates.min(by: { $0.value < $1.value })?.key {
                finishedExtensionUpdates[oldest] = nil
            }
            finishedExtensionUpdates[pending.id] = Date().addingTimeInterval(600)
            setSetupState(request.action == .extensionUpdateFailed ? .updateRequired : .checkingConnection)
            refreshReadiness()
        default: return CloudGatewayMacControllerReply(error: .invalidRequest)
        }
        do { try persistReceipts() }
        catch { return CloudGatewayMacControllerReply(error: .unavailable) }
        return reply(accepted: true)
    }

    private func bundledExtensionIdentity() throws -> CloudGatewayMacBuildIdentity {
        try CloudGatewayMacSignedBundle.installed(
            at: Self.installedURL.appendingPathComponent(
                "Contents/Library/SystemExtensions/com.gocloudlaunch.gateway.tunnel.macos.systemextension"
            ), teamIdentifier: teamIdentifier, bundleIdentifier: "com.gocloudlaunch.gateway.tunnel.macos"
        )
    }

    private static func bootSession() -> String {
        var bytes = [CChar](repeating: 0, count: 128)
        var length = bytes.count
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &length, nil, 0) == 0 else { return "unknown" }
        return String(cString: bytes)
    }

    private func refreshReadiness() {
        guard readinessTask == nil else { return }
        guard let identity = try? bundledExtensionIdentity(),
              let expected = CloudGatewayMacExtensionVersion(infoDictionary: [
                "CFBundleVersion": identity.build, "CFBundleShortVersionString": identity.version
              ], codeHash: identity.codeHash) else {
            setSetupState(.invalidBundle)
            return
        }
        if let pending = extensionUpdate {
            if pending.bootSession != Self.bootSession() {
                extensionUpdate = nil
                extensionEpoch &+= 1
                try? persistReceipts()
            } else if pending.phase == "prepared", pending.target != identity || pending.deadline.map({ $0 <= Date() }) == true {
                extensionUpdate = nil
                extensionEpoch &+= 1
                try? persistReceipts()
            } else if pending.target != identity || (pending.phase == "activating" && pending.deadline.map({ $0 <= Date() }) == true) {
                extensionUpdate?.phase = "restart"
                try? persistReceipts()
                setSetupState(.awaitingRestart)
                return
            } else if pending.phase == "restart" {
                setSetupState(.awaitingRestart)
                return
            } else if pending.phase == "approval" { setSetupState(.awaitingApproval) }
            else { setSetupState(.activating) }
        }
        if extensionUpdate?.phase == "prepared" { return }
        if extensionUpdate == nil, setupState != .ready { setSetupState(.checkingConnection) }
        let epoch = extensionEpoch
        readinessTask = Task { [weak self] in
            guard let self else { return }
            defer { readinessTask = nil }
            extensionIsIdle = (try? await !runtime.hasAnyActiveTunnel()) == true
            do {
                let client = try CloudGatewayMacXPCSecretClient(teamIdentifier: teamIdentifier)
                let version = try await client.ping()
                guard extensionEpoch == epoch else { return }
                let state = CloudGatewayMacSetupState.readiness(runningVersion: version, bundledVersion: expected)
                if state == .ready {
                    extensionUpdate = nil
                    try? persistReceipts()
                    setSetupState(.ready)
                } else if extensionUpdate?.phase == "approval" { setSetupState(.awaitingApproval) }
                else if extensionUpdate?.phase == "activating" { setSetupState(.activating) }
                else { setSetupState(state) }
            } catch {
                guard extensionEpoch == epoch else { return }
                if extensionUpdate == nil { setSetupState(.required) }
            }
        }
    }

    private func setSetupState(_ state: CloudGatewayMacSetupState) {
        setupState = state
        runtime.controller.setSetupState(state)
    }
}
