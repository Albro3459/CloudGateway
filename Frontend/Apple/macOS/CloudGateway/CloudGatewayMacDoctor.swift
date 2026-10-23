import CloudGatewayMacCLI
import CloudGatewayMacControllerIPC
import CloudGatewayMacCore
import CloudGatewayMacIPC
import Darwin
import dnssd
import Foundation
import Network

@MainActor
final class CloudGatewayMacDoctor {
    private typealias Check = CloudGatewayMacCLIDoctorReport.Check
    private let bundle: Bundle
    private let team: String
    private let connect: @MainActor () async throws -> CloudGatewayMacFrontendClient
    private var evidence: CloudGatewayMacControllerDiagnostics?
    private let installed = URL(fileURLWithPath: "/Applications/CloudGateway.app")
    private let dashboard = URL(string: "https://gocloudlaunch.com")!

    init(bundle: Bundle, team: String, connect: @escaping @MainActor () async throws -> CloudGatewayMacFrontendClient) {
        self.bundle = bundle
        self.team = team
        self.connect = connect
    }

    var runner: CloudGatewayMacCLIDoctor {
        .init(probes: [
            .init(name: "app", requirement: .setup) { await Task.detached(priority: .utility) { self.app() }.value },
            .init(name: "resources", requirement: .setup) { await Task.detached(priority: .utility) { self.resources() }.value },
            .init(name: "platform", requirement: .setup) { await Task.detached(priority: .utility) { self.platform() }.value },
            .init(name: "identity", requirement: .setup) { await self.identity() },
            .init(name: "cli_link", requirement: .optional) { await Task.detached(priority: .utility) { self.link() }.value },
            .init(name: "path", requirement: .optional) { await Task.detached(priority: .utility) { self.path() }.value },
            .init(name: "controller", requirement: .setup, timeout: .seconds(6)) { await self.controller() },
            .init(name: "extension", requirement: .setup) { self.extensionCheck() },
            .init(name: "preferences", requirement: .setup) { self.preferences() },
            .init(name: "credentials", requirement: .optional) { self.credentials() },
            .init(name: "access", requirement: .optional) { self.access() },
            .init(name: "network_path", requirement: .online) { await Self.networkPath() },
            .init(name: "dns", requirement: .online) { await Self.dns() },
            .init(name: "https", requirement: .online) { await self.https() },
            .init(name: "service", requirement: .optional) { await self.service() }
        ])
    }

    nonisolated private func app() -> Check {
        let canonical = bundle.bundleURL.standardizedFileURL == installed
            && bundle.bundleURL.resolvingSymlinksInPath() == installed
        return .init(name: "app", status: canonical ? .pass : .fail,
                     evidence: canonical ? "Using /Applications/CloudGateway.app" : "This copy is outside the canonical installed location",
                     suggestion: canonical ? nil : "Install CloudGateway in /Applications and run its bundled command")
    }

    nonisolated private func resources() -> Check {
        let extensionURL = installed.appendingPathComponent("Contents/Library/SystemExtensions/com.gocloudlaunch.gateway.tunnel.macos.systemextension")
        let firebaseURL = bundle.url(forResource: "GoogleService-Info", withExtension: "plist")
        let configuration = firebaseURL.flatMap { NSDictionary(contentsOf: $0) }
        let valid = configuration?["BUNDLE_ID"] as? String == CloudGatewayMacControllerProtocol.appBundleIdentifier
            && FileManager.default.fileExists(atPath: extensionURL.path)
        return .init(name: "resources", status: valid ? .pass : .fail,
                     evidence: valid ? "Firebase configuration and VPN extension are present" : "Required app resources are missing",
                     suggestion: valid ? nil : "Reinstall the complete CloudGateway app")
    }

    nonisolated private func platform() -> Check {
        var machine = utsname()
        uname(&machine)
        let architecture = withUnsafeBytes(of: &machine.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        let supported = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 && architecture == "arm64"
        return .init(name: "platform", status: supported ? .pass : .fail,
                     evidence: "macOS \(ProcessInfo.processInfo.operatingSystemVersionString), \(architecture)",
                     suggestion: supported ? nil : "Use macOS 26 or later on Apple silicon")
    }

    private func identity() async -> Check {
        await Task.detached(priority: .utility) { [installed, team] () -> Check in
            do {
                let running = try CloudGatewayMacSignedBundle.running(teamIdentifier: team,
                    bundleIdentifier: CloudGatewayMacControllerProtocol.appBundleIdentifier)
                let app = try CloudGatewayMacSignedBundle.installed(at: installed, teamIdentifier: team,
                    bundleIdentifier: CloudGatewayMacControllerProtocol.appBundleIdentifier)
                _ = try CloudGatewayMacSignedBundle.installed(at: installed.appendingPathComponent(
                    "Contents/Library/SystemExtensions/com.gocloudlaunch.gateway.tunnel.macos.systemextension"),
                    teamIdentifier: team, bundleIdentifier: "com.gocloudlaunch.gateway.tunnel.macos")
                return .init(name: "identity", status: running == app ? .pass : .fail,
                             evidence: running == app ? "App and extension signing identities verified" : "Running and installed app builds differ",
                             suggestion: running == app ? nil : "Run the installed command after the update finishes")
            } catch {
                return .init(name: "identity", status: .fail, evidence: "Component identities could not be verified",
                             suggestion: "Reinstall CloudGateway in /Applications")
            }
        }.value
    }

    nonisolated private var bin: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin") }

    nonisolated private func link() -> Check {
        let link = bin.appendingPathComponent("cloudgateway")
        let expected = installed.appendingPathComponent("Contents/MacOS/CloudGateway")
        let correct = (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil
            && link.resolvingSymlinksInPath() == expected
            && FileManager.default.isExecutableFile(atPath: expected.path)
        return .init(name: "cli_link", status: correct ? .pass : .warning,
                     evidence: correct ? "The user-local CLI link points to the installed executable" : "The user-local CLI link is absent, broken, or points elsewhere",
                     suggestion: correct ? nil : "Use Install Command Line Tool… in the CloudGateway menu")
    }

    nonisolated private func path() -> Check {
        let contains = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").contains { String($0) == bin.path }
        return .init(name: "path", status: contains ? .pass : .warning,
                     evidence: contains ? "The current PATH includes the user-local bin directory" : "The current PATH does not include the user-local bin directory",
                     suggestion: contains ? nil : "For SSH, invoke \(bin.appendingPathComponent("cloudgateway").path) explicitly")
    }

    private func controller() async -> Check {
        do {
            let client = try await connect()
            defer { client.shutdown() }
            let lifecycle = try await client.handshake()
            guard client.isCurrentBuild, lifecycle.state == .current else {
                return .init(name: "controller", status: .fail, evidence: "Controller build or protocol does not match",
                             suggestion: "Wait for app replacement to finish, then retry")
            }
            guard let diagnostics = try await client.send(.diagnostics).diagnostics else {
                return .init(name: "controller", status: .fail, evidence: "Controller diagnostic reply was missing")
            }
            evidence = diagnostics
            return .init(name: "controller", status: .pass, evidence: "Authenticated controller handshake and diagnostic protocol succeeded")
        } catch {
            return .init(name: "controller", status: .fail, evidence: "The authenticated controller probe did not complete",
                         suggestion: "Open the installed CloudGateway app once and retry doctor")
        }
    }

    private func extensionCheck() -> Check {
        switch evidence?.extensionState {
        case .ready: return .init(name: "extension", status: .pass, evidence: "The installed VPN extension answered an authenticated probe")
        case .enabled: return .init(name: "extension", status: .warning, evidence: "The extension is enabled, but runtime readiness is unverified")
        case .incompatible: return .init(name: "extension", status: .fail, evidence: "The authenticated running extension does not match the installed build", suggestion: "Open CloudGateway to finish the VPN extension update")
        case .awaitingApproval: return .init(name: "extension", status: .fail, evidence: "System Extensions reports pending user approval", suggestion: "Finish extension approval in System Settings on this Mac")
        case .disabled: return .init(name: "extension", status: .fail, evidence: "System Extensions reports the installed extension is disabled", suggestion: "Open CloudGateway to finish VPN setup")
        case .missing: return .init(name: "extension", status: .fail, evidence: "System Extensions did not report an installed extension", suggestion: "Open CloudGateway to install the VPN extension")
        case .unknown, nil: return .init(name: "extension", status: .unknown, evidence: "Extension approval and readiness could not be established")
        }
    }

    private func preferences() -> Check {
        if evidence?.preferences == .invalid {
            return .init(name: "preferences", status: .fail,
                         evidence: "An app-owned VPN profile has invalid or duplicate metadata",
                         suggestion: "Open CloudGateway to repair the installed VPN profiles")
        }
        return .init(name: "preferences", status: evidence?.preferences == .available ? .pass : .unknown,
              evidence: evidence?.preferences == .available
                ? "VPN preferences are readable. Write and start permission are unverified"
                : "Read access to VPN preferences could not be established")
    }

    private func credentials() -> Check {
        .init(name: "credentials", status: evidence?.credentials == .available ? .pass : .unknown,
              evidence: evidence?.credentials == .available ? "The initialized runtime reports available credentials"
                : "Credential availability is unknown. Doctor does not restore or exchange credentials")
    }

    private func access() -> Check {
        .init(name: "access", status: evidence?.access == .online || evidence?.access == .offline ? .pass : .unknown,
              evidence: evidence?.access.map { "Existing runtime access evidence: \($0.rawValue)" }
                ?? "Account access is uninitialized. Doctor does not restore or verify the account")
    }

    private static func networkPath() async -> Check {
        do {
            let available: Bool = try await CloudGatewayMacInventoryRequest.read(timeout: .seconds(3)) { complete in
                let monitor = NWPathMonitor()
                monitor.pathUpdateHandler = { complete(.success($0.status == .satisfied)) }
                monitor.start(queue: DispatchQueue(label: "CloudGateway.doctor.path"))
                return { monitor.cancel() }
            }
            return .init(name: "network_path", status: available ? .pass : .fail,
                         evidence: available ? "A network path is available" : "No network path is available")
        } catch { return .init(name: "network_path", status: .unknown, evidence: "Network path observation did not finish") }
    }

    private static func dns() async -> Check {
        do {
            let resolved: Bool = try await CloudGatewayMacInventoryRequest.read(timeout: .seconds(3)) { complete in
                let query = DoctorDNSQuery(complete: complete)
                query.start()
                return { query.cancel() }
            }
            return .init(name: "dns", status: resolved ? .pass : .fail,
                         evidence: resolved ? "The configured dashboard hostname resolved" : "The configured dashboard hostname did not resolve")
        } catch { return .init(name: "dns", status: .fail, evidence: "Dashboard DNS resolution did not finish") }
    }

    private func https() async -> Check {
        do {
            let (_, response) = try await Self.get(dashboard)
            let success = (200..<300).contains(response.statusCode)
            return .init(name: "https", status: success ? .pass : .fail,
                         evidence: success ? "The configured dashboard returned a successful HTTPS response" : "Dashboard HTTPS returned HTTP \(response.statusCode)")
        } catch { return .init(name: "https", status: .fail, evidence: "Dashboard HTTPS reachability could not be established") }
    }

    private func service() async -> Check {
        guard let region = evidence?.regionId, CloudGatewayMacControllerProtocol.validComponent(region),
              region.utf8.allSatisfy({ $0 == 45 || (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }),
              let url = URL(string: "https://\(region).gocloudlaunch.com/api/health") else {
            return .init(name: "service", status: .unknown, evidence: "No known regional API is available for an optional health check")
        }
        do {
            let (data, response) = try await Self.get(url, readBody: true)
            let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let valid = response.statusCode == 200 && body?["regionId"] as? String == region && body?["status"] as? String == "ok"
            return .init(name: "service", status: valid ? .pass : .warning,
                         evidence: valid ? "The known regional API reports healthy with matching region identity" : "The regional API did not return a matching healthy response")
        } catch { return .init(name: "service", status: .warning, evidence: "The optional regional health check did not complete") }
    }

    private static func get(_ url: URL, readBody: Bool = false) async throws -> (Data, HTTPURLResponse) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 4
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        let session = URLSession(configuration: config, delegate: DoctorHTTPDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(from: url)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        var data = Data()
        if readBody {
            for try await byte in bytes {
                guard data.count < 64 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
                data.append(byte)
            }
        }
        return (data, response)
    }
}

private final class DoctorHTTPDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private final class DoctorDNSQuery {
    private var reference: DNSServiceRef?
    private let complete: @Sendable (Result<Bool, Error>) -> Void

    init(complete: @escaping @Sendable (Result<Bool, Error>) -> Void) { self.complete = complete }

    func start() {
        let result = DNSServiceGetAddrInfo(&reference, 0, 0, DNSServiceProtocol(kDNSServiceProtocol_IPv4 | kDNSServiceProtocol_IPv6),
            "gocloudlaunch.com", { _, _, _, error, _, address, _, context in
                guard let context else { return }
                let query = Unmanaged<DoctorDNSQuery>.fromOpaque(context).takeUnretainedValue()
                if error == kDNSServiceErr_NoError, address != nil { query.complete(.success(true)) }
                else if error != kDNSServiceErr_NoSuchRecord { query.complete(.success(false)) }
            }, Unmanaged.passUnretained(self).toOpaque())
        guard result == kDNSServiceErr_NoError, let reference else { complete(.success(false)); return }
        if DNSServiceSetDispatchQueue(reference, .main) != kDNSServiceErr_NoError { complete(.success(false)) }
    }

    func cancel() {
        if let reference { DNSServiceRefDeallocate(reference) }
        reference = nil
    }
}
