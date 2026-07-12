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

    // Tunnel-health polling. Runs entirely inside the extension so it keeps
    // working when the app is backgrounded, closed, or signed out.
    private let healthQueue = DispatchQueue(label: "com.gocloudlaunch.gateway.tunnel.health")
    private let healthPollInterval: TimeInterval = 5
    // Persist on every state transition, and otherwise at most once per heartbeat
    // so the stored snapshot stays inside GatewayTunnelHealthStore.freshnessWindow
    // (30s) without rewriting the protected file on every 5s poll.
    private var healthTimer: DispatchSourceTimer?
    private var healthEvaluator: GatewayTunnelHealthEvaluator?
    private var recoveryPolicy = GatewayTunnelRecoveryPolicy()
    private var healthStore: GatewayTunnelHealthStore?
    private var healthTunnelIdentifier: String?
    private var lastPublishedHealth: GatewayTunnelHealth?
    private var healthPersistencePolicy = GatewayTunnelHealthPersistencePolicy()
    private var healthReadInFlight = false
    private var healthSessionGeneration: UInt64 = 0
    private var policyPathGeneration: UInt64 = 0
    private var pathFingerprint: HealthPathFingerprint?
    private var satisfiedSince: Date?
    private var lastPathChangeAt: Date?
    private var pathMonitor: NWPathMonitor?

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        do {
            let tunnelConfiguration = try makeTunnelConfiguration()
            adapter.start(tunnelConfiguration: tunnelConfiguration) { [weak self] error in
                if error == nil {
                    self?.startHealthMonitoring()
                }
                completionHandler(error)
            }
        } catch {
            completionHandler(error)
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        stopHealthMonitoring()
        adapter.stop { _ in
            completionHandler()
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

    private func startHealthMonitoring() {
        guard let providerConfiguration = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration,
              let appGroupIdentifier = providerConfiguration[GatewayProviderConfigurationKey.appGroupIdentifier] as? String,
              let tunnelIdentifier = providerConfiguration[GatewayProviderConfigurationKey.tunnelIdentifier] as? String else {
            return
        }
        healthQueue.async { [weak self] in
            guard let self else { return }
            // Clear any notification left over from a prior process: iOS can kill
            // and relaunch the extension without a stopTunnel, and the fresh
            // evaluator warms up through .unknown, so recovery alone would not
            // withdraw a stale "not responding" notification.
            self.withdrawDeadTunnelNotification()
            self.healthTunnelIdentifier = tunnelIdentifier
            self.healthStore = GatewayTunnelHealthStore(appGroupIdentifier: appGroupIdentifier)
            // Do not let a fresh extension session inherit a dead verdict from
            // the previous process. The first new runtime sample will publish
            // .unknown, .passingTraffic, or .notPassingTraffic for this session.
            try? self.healthStore?.clear()
            self.healthEvaluator = GatewayTunnelHealthEvaluator(startedAt: Date())
            self.recoveryPolicy = GatewayTunnelRecoveryPolicy()
            self.lastPublishedHealth = nil
            self.healthPersistencePolicy = GatewayTunnelHealthPersistencePolicy()
            self.healthReadInFlight = false
            self.healthSessionGeneration &+= 1
            self.policyPathGeneration = 0
            self.pathFingerprint = nil
            self.satisfiedSince = nil
            self.lastPathChangeAt = nil

            let pathMonitor = NWPathMonitor()
            pathMonitor.pathUpdateHandler = { [weak self] path in
                self?.receivePathUpdate(path)
            }
            self.pathMonitor = pathMonitor
            pathMonitor.start(queue: self.healthQueue)

            let timer = DispatchSource.makeTimerSource(queue: self.healthQueue)
            timer.schedule(deadline: .now() + self.healthPollInterval, repeating: self.healthPollInterval)
            timer.setEventHandler { [weak self] in
                self?.pollTunnelHealth()
            }
            self.healthTimer = timer
            timer.resume()
        }
    }

    // Synchronous so the stale health flag is guaranteed cleared before
    // stopTunnel's completion fires - iOS may suspend/terminate the extension
    // immediately after, and an enqueued clear could otherwise never run.
    private func stopHealthMonitoring() {
        healthQueue.sync {
            healthTimer?.cancel()
            healthTimer = nil
            pathMonitor?.cancel()
            pathMonitor = nil
            healthEvaluator = nil
            recoveryPolicy = GatewayTunnelRecoveryPolicy()
            try? healthStore?.clear()
            healthStore = nil
            healthTunnelIdentifier = nil
            lastPublishedHealth = nil
            healthPersistencePolicy = GatewayTunnelHealthPersistencePolicy()
            healthReadInFlight = false
            healthSessionGeneration &+= 1
            policyPathGeneration &+= 1
            pathFingerprint = nil
            satisfiedSince = nil
            lastPathChangeAt = nil
        }
        withdrawDeadTunnelNotification()
    }

    // Called on healthQueue. Reads the tunnel's runtime stats, updates the
    // evaluator, and publishes the verdict to the shared app group.
    private func pollTunnelHealth() {
        guard !healthReadInFlight else { return }
        healthReadInFlight = true
        let sessionGeneration = healthSessionGeneration
        adapter.getRuntimeConfiguration { [weak self] configuration in
            self?.healthQueue.async {
                guard let self, sessionGeneration == self.healthSessionGeneration else {
                    return
                }
                self.healthReadInFlight = false
                let now = Date()
                let stats = configuration.flatMap(GatewayTunnelRuntimeStats.parse)
                var evidence: GatewayTunnelHealthEvidence?
                if let stats, var evaluator = self.healthEvaluator {
                    evidence = evaluator.evaluateEvidence(stats, at: now)
                    self.healthEvaluator = evaluator
                }
                let action = self.recoveryPolicy.update(
                    stats: stats,
                    evidence: evidence,
                    path: self.pathAvailability(at: now),
                    routeGeneration: self.policyPathGeneration,
                    at: now
                )
                self.publishHealth(action.health, at: now)
                if action.requestBindingRefresh {
                    self.requestBindingRefresh(sessionGeneration: sessionGeneration, baseline: stats)
                }
            }
        }
    }

    private func receivePathUpdate(_ path: Network.NWPath) {
        let now = Date()
        let fingerprint = HealthPathFingerprint(path)
        guard fingerprint != pathFingerprint else { return }

        let wasContinuouslySatisfied = satisfiedSince != nil
        pathFingerprint = fingerprint
        lastPathChangeAt = now

        if path.status == .satisfied {
            if !wasContinuouslySatisfied {
                satisfiedSince = now
            }
            if now.timeIntervalSince(satisfiedSince ?? now) < 30 {
                policyPathGeneration &+= 1
            }
        } else {
            satisfiedSince = nil
            policyPathGeneration &+= 1
        }
    }

    private func pathAvailability(at now: Date) -> GatewayTunnelPathAvailability {
        guard pathFingerprint?.status == .satisfied, let satisfiedSince, let lastPathChangeAt else {
            return .unavailable
        }
        let continuouslySatisfiedAge = now.timeIntervalSince(satisfiedSince)
        let quietAge = now.timeIntervalSince(lastPathChangeAt)
        return quietAge >= 10 || continuouslySatisfiedAge >= 30 ? .satisfied : .settling
    }

    private func requestBindingRefresh(sessionGeneration: UInt64, baseline: GatewayTunnelRuntimeStats?) {
        let routeGeneration = policyPathGeneration
        adapter.refreshNetworkBinding { [weak self] error in
            self?.healthQueue.async {
                guard let self, sessionGeneration == self.healthSessionGeneration else {
                    return
                }
                guard routeGeneration == self.policyPathGeneration else {
                    self.recoveryPolicy.invalidatePendingBindingRefresh()
                    return
                }
                let accepted = error == nil
                let now = Date()
                self.recoveryPolicy.bindingRefreshCompleted(accepted: accepted, at: now)
                if accepted {
                    // Seed the fresh one-way window with the sample that opened
                    // this attempt so the next poll can start a new candidate
                    // instead of discarding the first post-refresh sample.
                    self.healthEvaluator?.resetTrafficEvidence(baseline: baseline, at: now)
                }
            }
        }
    }

    private func publishHealth(_ health: GatewayTunnelHealth, at now: Date) {
        guard let store = healthStore, let tunnelIdentifier = healthTunnelIdentifier else { return }
        if healthPersistencePolicy.shouldPersist(health, at: now) {
            do {
                try store.write(GatewayTunnelHealthSnapshot(
                    tunnelIdentifier: tunnelIdentifier,
                    health: health,
                    updatedAt: now
                ))
                healthPersistencePolicy.recordPersisted(health, at: now)
            } catch {
                // Leave the policy unchanged so the next poll retries.
            }
        }

        let previous = lastPublishedHealth
        lastPublishedHealth = health
        if GatewayTunnelHealthNotification.shouldNotify(previous: previous, current: health) {
            postDeadTunnelNotification()
        } else if GatewayTunnelHealthNotification.shouldWithdraw(previous: previous, current: health) {
            withdrawDeadTunnelNotification()
        }
    }

    private func postDeadTunnelNotification() {
        let content = UNMutableNotificationContent()
        content.title = GatewayTunnelHealthNotification.title
        content.body = GatewayTunnelHealthNotification.body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: GatewayTunnelHealthNotification.identifier,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func withdrawDeadTunnelNotification() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [GatewayTunnelHealthNotification.identifier])
        center.removeDeliveredNotifications(withIdentifiers: [GatewayTunnelHealthNotification.identifier])
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
