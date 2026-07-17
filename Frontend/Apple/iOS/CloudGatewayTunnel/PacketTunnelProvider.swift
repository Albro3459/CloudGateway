import CloudGatewayKit
import Network
import NetworkExtension
import os
import UserNotifications
import WireGuardKit

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private lazy var adapter = WireGuardAdapter(with: self) { level, message in
        let logType: OSLogType = level == .error ? .error : .debug
        os_log("%{private}@", log: .default, type: logType, message)
    }

    private let healthPathQueue = DispatchQueue(label: "com.gocloudlaunch.gateway.tunnel.health.path")
    private let healthLifecycle = IOSTunnelHealthLifecycle()
    private lazy var healthRuntime = IOSTunnelHealthRuntimeAdapter(adapter: adapter)
    private let healthNotifications = IOSTunnelHealthNotificationAdapter()
    private let adapterStopCompletionDeadline: DispatchTimeInterval = .seconds(5)

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let startID = healthLifecycle.beginStartAttempt()
        do {
            let tunnelConfiguration = try makeTunnelConfiguration()
            let submitted = healthLifecycle.submitAdapterStart(startID: startID) {
                adapter.start(tunnelConfiguration: tunnelConfiguration) { [weak self] error in
                    guard let self else {
                        completionHandler(error)
                        return
                    }
                    guard error == nil else {
                        completionHandler(error)
                        self.healthLifecycle.pendingStartDidStop(startID: startID)
                        return
                    }
                    self.startHealthMonitoring(
                        startID: startID,
                        completionHandler: completionHandler
                    )
                }
            }
            if !submitted {
                completionHandler(nil)
                healthLifecycle.pendingStartDidStop(startID: startID)
            }
        } catch {
            completionHandler(error)
            healthLifecycle.pendingStartDidStop(startID: startID)
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        let stopCompletion = GatewayTunnelStopCompletion(completion: completionHandler)
        let adapterStop = GatewayTunnelStopSubmission(
            targetQueue: healthPathQueue,
            submission: { [weak self] in
                guard let self else {
                    stopCompletion.adapterStopped()
                    return
                }
                self.adapter.stop { _ in
                    stopCompletion.adapterStopped()
                }
            }
        )
        let stopDeadline = IOSTunnelHealthStopDeadline {
            adapterStop.submit {
                stopCompletion.deadlineExceeded()
            }
        }
        healthPathQueue.asyncAfter(deadline: .now() + adapterStopCompletionDeadline) {
            stopDeadline.fire()
        }
        let healthStop = healthLifecycle.prepareToStop {
            stopCompletion.healthStopped()
        }
        stopDeadline.install(token: healthStop.token)
        if let token = healthStop.token {
            stopCompletion.setDeadlineCleanup {
                token.bestEffortDeadlineCleanup()
            }
        }
        if let monitor = healthStop.monitor, let token = healthStop.token {
            Task {
                await monitor.stop(token) {
                    healthStop.join.monitorStopped()
                }
            }
        }
        if let token = healthStop.token {
            token.enqueueAfterSubmittedEffects {
                adapterStop.submit()
            }
        } else {
            adapterStop.submit()
        }
    }

    private func startHealthMonitoring(
        startID: UInt64,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard let providerConfiguration = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration,
              let appGroupIdentifier = providerConfiguration[GatewayProviderConfigurationKey.appGroupIdentifier] as? String,
              let tunnelIdentifier = providerConfiguration[GatewayProviderConfigurationKey.tunnelIdentifier] as? String else {
            completionHandler(nil)
            healthLifecycle.pendingStartDidStop(startID: startID)
            return
        }
        guard let start = healthLifecycle.continueStart(
            startID: startID,
            appGroupIdentifier: appGroupIdentifier,
            runtime: healthRuntime,
            notifications: healthNotifications
        ) else {
            completionHandler(nil)
            healthLifecycle.pendingStartDidStop(startID: startID)
            return
        }
        Task { [weak self] in
            guard let session = await start.monitor.start(tunnelIdentifier: tunnelIdentifier) else {
                completionHandler(GatewayVPNError.missingTunnelSession)
                start.lifecycle.pendingStartDidStop(startID: start.id)
                return
            }
            guard let self else {
                completionHandler(nil)
                if let token = start.monitor.prepareToStop(session: session) {
                    await start.monitor.stop(token) {
                        start.lifecycle.pendingStartDidStop(startID: start.id)
                    }
                } else {
                    start.lifecycle.pendingStartDidStop(startID: start.id)
                }
                return
            }
            let pathSession = IOSTunnelHealthPathSession(
                monitor: start.monitor,
                session: session,
                queue: self.healthPathQueue
            )
            guard self.healthLifecycle.install(
                pathSession: pathSession,
                startID: start.id
            ) else {
                pathSession.cancel()
                completionHandler(nil)
                if let token = start.monitor.prepareToStop(session: session) {
                    await start.monitor.stop(token) {
                        start.lifecycle.pendingStartDidStop(startID: start.id)
                    }
                } else {
                    start.lifecycle.pendingStartDidStop(startID: start.id)
                }
                return
            }
            pathSession.start()
            completionHandler(nil)
            self.healthLifecycle.pendingStartDidStop(startID: start.id)
        }
    }

    private func makeTunnelConfiguration() throws -> TunnelConfiguration {
        guard let protocolConfiguration = protocolConfiguration as? NETunnelProviderProtocol,
              let providerConfiguration = protocolConfiguration.providerConfiguration,
              let keychainService = providerConfiguration[GatewayProviderConfigurationKey.keychainService] as? String,
              let keychainAccount = providerConfiguration[GatewayProviderConfigurationKey.keychainAccount] as? String else {
            throw GatewayVPNError.missingConfigSecretReference
        }

        let secretStore = GatewayKeychainConfigSecretStore(
            accessGroup: providerConfiguration[GatewayProviderConfigurationKey.keychainAccessGroup] as? String
        )
        let secretReference = GatewayConfigSecretReference(
            service: keychainService,
            account: keychainAccount
        )
        let wireGuardConfig = try secretStore.loadConfig(for: secretReference).rawValue
        let tunnelName = protocolConfiguration.serverAddress ?? "CloudGateway"
        return try GatewayWireGuardConfigParser.parse(wireGuardConfig, named: tunnelName).wireGuardTunnelConfiguration()
    }

}

private final class IOSTunnelHealthRuntimeAdapter:
    GatewayTunnelHealthRuntimeAdapter,
    @unchecked Sendable
{
    let backendRestartCapability = GatewayTunnelBackendRestartCapability.supported
    private let adapter: WireGuardAdapter

    init(adapter: WireGuardAdapter) {
        self.adapter = adapter
    }

    // WireGuardAdapter confines every public operation and callback to its
    // private work queue. This wrapper never reads or mutates the adapter state.
    func readRuntime(
        completion: @escaping @Sendable (GatewayTunnelRuntimeStats?) async -> Void
    ) {
        adapter.getRuntimeConfiguration { configuration in
            let stats = configuration.flatMap(GatewayTunnelRuntimeStats.parse)
            Task { await completion(stats) }
        }
    }

    func refreshBinding(
        completion: @escaping @Sendable (GatewayTunnelRecoveryResult) async -> Void
    ) {
        adapter.refreshNetworkBinding { error in
            Task { await completion(error == nil ? .accepted : .rejected) }
        }
    }

    func restartBackend(
        completion: @escaping @Sendable (GatewayTunnelRecoveryResult) async -> Void
    ) {
        adapter.restartBackend { error in
            Task { await completion(error == nil ? .accepted : .rejected) }
        }
    }
}

private final class IOSTunnelHealthNotificationAdapter:
    GatewayTunnelHealthNotificationAdapter,
    @unchecked Sendable
{
    private let center = UNUserNotificationCenter.current()
    private let registrationFence = GatewayTunnelHealthNotificationRegistrationFence()

    func resumeRegistrations() {
        registrationFence.resume()
    }

    func suspendRegistrations() {
        registrationFence.suspend()
    }

    func invalidateRegistrations() {
        registrationFence.invalidate()
    }

    func register(
        completion: @escaping @Sendable (GatewayTunnelNotificationResult) async -> Void
    ) {
        registrationFence.register(
            authorization: { [center] callback in
                center.getNotificationSettings { settings in
                    let result: GatewayTunnelHealthNotificationAuthorizationResult
                    switch settings.authorizationStatus {
                    case .authorized, .provisional, .ephemeral:
                        result = .allowed
                    case .denied:
                        result = .terminalFailure
                    case .notDetermined:
                        result = .retryableFailure
                    @unknown default:
                        result = .retryableFailure
                    }
                    callback(result)
                }
            },
            add: { [center] callback in
                let content = UNMutableNotificationContent()
                content.title = GatewayTunnelHealthNotification.title
                content.body = GatewayTunnelHealthNotification.body
                content.sound = .default
                let request = UNNotificationRequest(
                    identifier: GatewayTunnelHealthNotification.identifier,
                    content: content,
                    trigger: nil
                )
                center.add(request) { error in
                    if error == nil {
                        callback(.registered)
                    } else if Self.notificationsAreNotAllowed(error) {
                        callback(.terminalFailure)
                    } else {
                        callback(.retryableFailure)
                    }
                }
            },
            remove: { [center] in
                Self.removeStableNotification(from: center)
            },
            completion: completion
        )
    }

    func reconcile(
        completion: @escaping @Sendable (GatewayTunnelNotificationResult) async -> Void
    ) {
        withAuthorization(completion: completion) { [center] in
            let reconciliation = IOSTunnelHealthNotificationReconciliation(
                completion: completion
            )
            center.getPendingNotificationRequests { requests in
                reconciliation.recordPending(requests.contains {
                    $0.identifier == GatewayTunnelHealthNotification.identifier
                })
            }
            center.getDeliveredNotifications { notifications in
                reconciliation.recordDelivered(notifications.contains {
                    $0.request.identifier == GatewayTunnelHealthNotification.identifier
                })
            }
        }
    }

    func withdraw() {
        registrationFence.withdraw { [center] in
            Self.removeStableNotification(from: center)
        }
    }

    private func withAuthorization(
        completion: @escaping @Sendable (GatewayTunnelNotificationResult) async -> Void,
        authorized: @escaping @Sendable () -> Void
    ) {
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                authorized()
            case .denied:
                Task { await completion(.terminalFailure) }
            case .notDetermined:
                Task { await completion(.retryableFailure) }
            @unknown default:
                Task { await completion(.retryableFailure) }
            }
        }
    }

    private static func notificationsAreNotAllowed(_ error: Error?) -> Bool {
        guard let error else { return false }
        let nsError = error as NSError
        return nsError.domain == UNErrorDomain &&
            nsError.code == UNError.Code.notificationsNotAllowed.rawValue
    }

    private static func removeStableNotification(
        from center: UNUserNotificationCenter
    ) {
        let identifiers = [GatewayTunnelHealthNotification.identifier]
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}

private final class IOSTunnelHealthNotificationReconciliation: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: Bool?
    private var delivered: Bool?
    private var completion: (@Sendable (GatewayTunnelNotificationResult) async -> Void)?

    init(
        completion: @escaping @Sendable (GatewayTunnelNotificationResult) async -> Void
    ) {
        self.completion = completion
    }

    func recordPending(_ isPresent: Bool) {
        record(isPresent, pendingResult: true)
    }

    func recordDelivered(_ isPresent: Bool) {
        record(isPresent, pendingResult: false)
    }

    private func record(_ isPresent: Bool, pendingResult: Bool) {
        lock.lock()
        if pendingResult {
            pending = isPresent
        } else {
            delivered = isPresent
        }
        guard let pending, let delivered, let completion else {
            lock.unlock()
            return
        }
        self.completion = nil
        lock.unlock()
        let result: GatewayTunnelNotificationResult = pending || delivered
            ? .registered
            : .absent
        Task { await completion(result) }
    }
}

private final class IOSTunnelHealthLifecycle: @unchecked Sendable {
    struct Start: Sendable {
        let id: UInt64
        let monitor: GatewayTunnelHealthMonitor
        let lifecycle: IOSTunnelHealthLifecycle
    }

    struct Stop: Sendable {
        let monitor: GatewayTunnelHealthMonitor?
        let token: GatewayTunnelHealthStopToken?
        let join: GatewayTunnelStartStopJoin
    }

    private let lock = NSLock()
    private var monitor: GatewayTunnelHealthMonitor?
    private var activeStartID: UInt64?
    private var stopping = false
    private var pathSession: IOSTunnelHealthPathSession?
    private let pendingStartBarrier = GatewayTunnelPendingStartBarrier()

    func beginStartAttempt() -> UInt64 {
        lock.lock()
        let startID = pendingStartBarrier.begin()
        activeStartID = startID
        stopping = false
        lock.unlock()
        return startID
    }

    func continueStart(
        startID: UInt64,
        appGroupIdentifier: String,
        runtime: IOSTunnelHealthRuntimeAdapter,
        notifications: IOSTunnelHealthNotificationAdapter
    ) -> Start? {
        lock.lock()
        guard activeStartID == startID,
              !stopping,
              pendingStartBarrier.canContinue(startID) else {
            lock.unlock()
            return nil
        }
        if monitor == nil {
            monitor = GatewayTunnelHealthMonitor(
                runtime: runtime,
                persistence: GatewayTunnelHealthStoreAdapter(
                    store: GatewayTunnelHealthStore(
                        appGroupIdentifier: appGroupIdentifier
                    )
                ),
                notifications: notifications
            )
        }
        let start = Start(
            id: startID,
            monitor: monitor!,
            lifecycle: self
        )
        lock.unlock()
        return start
    }

    func submitAdapterStart(
        startID: UInt64,
        submission: () -> Void
    ) -> Bool {
        lock.lock()
        guard activeStartID == startID, !stopping else {
            lock.unlock()
            return false
        }
        let submitted = pendingStartBarrier.performIfCanContinue(
            startID,
            submission
        )
        lock.unlock()
        return submitted
    }

    func install(
        pathSession: IOSTunnelHealthPathSession,
        startID: UInt64
    ) -> Bool {
        lock.lock()
        guard activeStartID == startID, !stopping else {
            lock.unlock()
            return false
        }
        let oldPathSession = self.pathSession
        self.pathSession = pathSession
        lock.unlock()
        oldPathSession?.cancel()
        return true
    }

    func prepareToStop(
        pendingStartStopped: @escaping @Sendable () -> Void
    ) -> Stop {
        lock.lock()
        stopping = true
        let pathSession = pathSession
        self.pathSession = nil
        let monitor = monitor
        let token = monitor?.prepareToStop()
        let join = pendingStartBarrier.prepareJoinedStop(
            completion: pendingStartStopped
        )
        lock.unlock()
        pathSession?.cancel()
        if token == nil {
            join.monitorStopped()
        }
        return Stop(
            monitor: monitor,
            token: token,
            join: join
        )
    }

    func pendingStartDidStop(startID: UInt64) {
        pendingStartBarrier.complete(startID)
    }
}

private final class IOSTunnelHealthStopDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private let deadlineStop: @Sendable () -> Void
    private var token: GatewayTunnelHealthStopToken?
    private var installed = false
    private var fired = false

    init(deadlineStop: @escaping @Sendable () -> Void) {
        self.deadlineStop = deadlineStop
    }

    func install(token: GatewayTunnelHealthStopToken?) {
        lock.lock()
        self.token = token
        installed = true
        let deadlineAlreadyFired = fired
        lock.unlock()
        if deadlineAlreadyFired {
            if let token {
                token.cancelQueuedEffectsAndEnqueue(deadlineStop)
            } else {
                deadlineStop()
            }
        }
    }

    func fire() {
        lock.lock()
        guard !fired else {
            lock.unlock()
            return
        }
        fired = true
        let installed = installed
        let token = token
        lock.unlock()
        guard installed else { return }
        if let token {
            token.cancelQueuedEffectsAndEnqueue(deadlineStop)
        } else {
            deadlineStop()
        }
    }
}

private final class IOSTunnelHealthPathSession: @unchecked Sendable {
    private let lock = NSLock()
    private let monitor: GatewayTunnelHealthMonitor
    private let session: GatewayTunnelHealthSession
    private let queue: DispatchQueue
    private let pathMonitor = NWPathMonitor()
    private var active = true
    private var fingerprint: HealthPathFingerprint?
    private var routeID: UInt64 = 0

    init(
        monitor: GatewayTunnelHealthMonitor,
        session: GatewayTunnelHealthSession,
        queue: DispatchQueue
    ) {
        self.monitor = monitor
        self.session = session
        self.queue = queue
        pathMonitor.pathUpdateHandler = { [weak self] path in
            self?.receive(path)
        }
    }

    func start() {
        lock.lock()
        guard active else {
            lock.unlock()
            return
        }
        pathMonitor.start(queue: queue)
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        active = false
        lock.unlock()
        pathMonitor.cancel()
    }

    private func receive(_ path: Network.NWPath) {
        let nextFingerprint = HealthPathFingerprint(path)
        lock.lock()
        guard active, fingerprint != nextFingerprint else {
            lock.unlock()
            return
        }
        fingerprint = nextFingerprint
        routeID &+= 1
        let descriptor = GatewayTunnelPathDescriptor(
            isSatisfied: path.status == .satisfied,
            routeID: routeID
        )
        lock.unlock()
        Task {
            await monitor.pathChanged(descriptor, session: session)
        }
    }
}

private struct HealthPathFingerprint: Equatable {
    enum Status: Equatable {
        case satisfied
        case unsatisfied
        case requiresConnection
    }

    let status: Status
    let interfaceTypes: [NWInterface.InterfaceType]
    let gateways: [String]
    let supportsIPv4: Bool
    let supportsIPv6: Bool
    let supportsDNS: Bool

    init(_ path: Network.NWPath) {
        switch path.status {
        case .satisfied: status = .satisfied
        case .requiresConnection: status = .requiresConnection
        default: status = .unsatisfied
        }
        interfaceTypes = [.wifi, .cellular, .wiredEthernet, .loopback, .other]
            .filter(path.usesInterfaceType)
        gateways = path.gateways.map(String.init(describing:)).sorted()
        supportsIPv4 = path.supportsIPv4
        supportsIPv6 = path.supportsIPv6
        supportsDNS = path.supportsDNS
    }
}

private extension GatewayParsedWireGuardConfig {
    func wireGuardTunnelConfiguration() throws -> TunnelConfiguration {
        TunnelConfiguration(
            name: name,
            interface: try interface.wireGuardInterfaceConfiguration(),
            peers: try peers.map { try $0.wireGuardPeerConfiguration() }
        )
    }
}

private extension GatewayParsedWireGuardInterface {
    func wireGuardInterfaceConfiguration() throws -> InterfaceConfiguration {
        guard let privateKey = PrivateKey(base64Key: privateKey) else {
            throw GatewayWireGuardConfigParser.ParseError.interfaceHasInvalidPrivateKey
        }

        var configuration = InterfaceConfiguration(privateKey: privateKey)
        configuration.listenPort = listenPort
        configuration.addresses = try addresses.map { address in
            guard let addressRange = IPAddressRange(from: address) else {
                throw GatewayWireGuardConfigParser.ParseError.interfaceHasInvalidAddress(address)
            }
            return addressRange
        }
        configuration.dns = try dns.map { dnsValue in
            guard let dnsServer = DNSServer(from: dnsValue) else {
                throw GatewayWireGuardConfigParser.ParseError.interfaceHasInvalidDNS(dnsValue)
            }
            return dnsServer
        }
        configuration.dnsSearch = dnsSearch
        configuration.mtu = mtu
        return configuration
    }
}

private extension GatewayParsedWireGuardPeer {
    func wireGuardPeerConfiguration() throws -> PeerConfiguration {
        guard let publicKey = PublicKey(base64Key: publicKey) else {
            throw GatewayWireGuardConfigParser.ParseError.peerHasInvalidPublicKey(self.publicKey)
        }

        var configuration = PeerConfiguration(publicKey: publicKey)
        if let preSharedKey {
            guard let wireGuardPreSharedKey = PreSharedKey(base64Key: preSharedKey) else {
                throw GatewayWireGuardConfigParser.ParseError.peerHasInvalidPreSharedKey
            }
            configuration.preSharedKey = wireGuardPreSharedKey
        }
        configuration.allowedIPs = try allowedIPs.map { allowedIP in
            guard let allowedIPRange = IPAddressRange(from: allowedIP) else {
                throw GatewayWireGuardConfigParser.ParseError.peerHasInvalidAllowedIP(allowedIP)
            }
            return allowedIPRange
        }
        if let endpoint {
            guard let wireGuardEndpoint = Endpoint(from: endpoint) else {
                throw GatewayWireGuardConfigParser.ParseError.peerHasInvalidEndpoint(endpoint)
            }
            configuration.endpoint = wireGuardEndpoint
        }
        configuration.persistentKeepAlive = persistentKeepAlive
        return configuration
    }
}
