import CloudGatewayMacControllerIPC
import CloudGatewayMacCore
import CloudGatewayMacIPC
import Darwin
import Foundation

@MainActor
final class CloudGatewayMacControllerService {
    private struct Creation {
        let id: UUID
        let context: CloudGatewayMacClientCreationContext
        let expires: ContinuousClock.Instant
    }

    private struct Receipt {
        let request: CloudGatewayMacControllerRequest
        let accepted: Bool
        let expires: ContinuousClock.Instant
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

    init() throws {
        ownership = try CloudGatewayMacControllerOwnership(directory: CloudGatewayMacControllerRuntime.directory)
        teamIdentifier = Bundle.main.object(forInfoDictionaryKey: "CloudGatewayTeamIdentifier") as? String ?? ""
        runtime = CloudGatewayMacControllerRuntime()
        server = try CloudGatewayMacControllerServer(
            teamIdentifier: teamIdentifier,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        ) { [weak self] request in
            guard let self else { return CloudGatewayMacControllerReply(error: .unavailable) }
            return await handle(request)
        }
    }

    func run() {
        runtime.controller.onChange = { [weak self] in
            // Preserve the result for a full reconnect grace period after work completes
            self?.lastActivity = ContinuousClock().now
        }
        runtime.controller.start()
        refreshReadiness()
        server.resume()
        Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) }
                catch { return }
                guard let self else { return }
                if runtime.controller.hasPendingWork || activeRequests > 0 || readinessTask != nil {
                    lastActivity = clock.now
                } else if lastActivity.duration(to: clock.now) >= .seconds(60) {
                    server.invalidate()
                    runtime.shutdown()
                    exit(EXIT_SUCCESS)
                }
            }
        }
    }

    private func reply(accepted: Bool? = nil, operationId: UUID? = nil) -> CloudGatewayMacControllerReply {
        CloudGatewayMacControllerReply(
            snapshot: CloudGatewayMacControllerView(snapshot: runtime.controller.snapshot(setupState: setupState),
                                                    setupState: setupState),
            accepted: accepted, operationId: operationId
        )
    }

    private func handle(_ request: CloudGatewayMacControllerRequest) async -> CloudGatewayMacControllerReply {
        activeRequests += 1
        lastActivity = clock.now
        defer { activeRequests -= 1; lastActivity = clock.now }
        receipts = receipts.filter { $0.value.expires > clock.now }
        if let receipt = receipts[request.id] {
            guard receipt.request == request else { return CloudGatewayMacControllerReply(error: .invalidRequest) }
            return receipt.accepted ? reply(accepted: true, operationId: request.id)
                : CloudGatewayMacControllerReply(error: .busy)
        }
        let controller = runtime.controller
        switch request.action {
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

    private func record(_ request: CloudGatewayMacControllerRequest, accepted: Bool) -> CloudGatewayMacControllerReply {
        if receipts.count >= 64, let oldest = receipts.min(by: { $0.value.expires < $1.value.expires })?.key {
            receipts.removeValue(forKey: oldest)
        }
        receipts[request.id] = Receipt(request: request, accepted: accepted, expires: clock.now.advanced(by: .seconds(60)))
        return accepted ? reply(accepted: true, operationId: request.id) : CloudGatewayMacControllerReply(error: .busy)
    }

    private func refreshReadiness() {
        guard readinessTask == nil else { return }
        let extensionURL = Bundle.main.bundleURL.appendingPathComponent(
            "Contents/Library/SystemExtensions/com.gocloudlaunch.gateway.tunnel.macos.systemextension"
        )
        guard let info = Bundle(url: extensionURL)?.infoDictionary,
              let expected = CloudGatewayMacExtensionVersion(infoDictionary: info) else {
            setSetupState(.invalidBundle)
            return
        }
        setSetupState(.checkingConnection)
        readinessTask = Task { [weak self] in
            guard let self else { return }
            defer { readinessTask = nil }
            do {
                let client = try CloudGatewayMacXPCSecretClient(teamIdentifier: teamIdentifier)
                let version = try await client.ping()
                setSetupState(.readiness(runningVersion: version, bundledVersion: expected))
            } catch {
                setSetupState(.required)
            }
        }
    }

    private func setSetupState(_ state: CloudGatewayMacSetupState) {
        setupState = state
        runtime.controller.setSetupState(state)
    }
}
