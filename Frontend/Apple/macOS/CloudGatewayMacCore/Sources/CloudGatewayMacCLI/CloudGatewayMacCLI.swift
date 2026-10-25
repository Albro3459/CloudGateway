import CloudGatewayMacControllerIPC
import Foundation

public enum CloudGatewayMacLaunchMode: Equatable {
    case menu, controller, cli([String]), conflict

    // The symlink name comes from argv[0] as invoked, before any symlink resolution
    public init(arguments: [String]) {
        let name = arguments.first?.split(separator: "/").last.map(String.init) ?? ""
        let options = Array(arguments.dropFirst())
        let isPrivate = { (argument: String) in argument == "--controller" || argument == "--cli" }
        if name == "cloudgateway" {
            self = options.first == "--controller" ? .conflict
                : .cli(Array(options.dropFirst(options.first == "--cli" ? 1 : 0)))
        } else if options.first == "--controller" {
            self = options.count == 1 ? .controller : .conflict
        } else if options.first == "--cli" {
            self = .cli(Array(options.dropFirst()))
        } else {
            self = options.contains(where: isPrivate) ? .conflict : .menu
        }
    }
}

@MainActor
public struct CloudGatewayMacCLI {
    private let version: String
    private let build: String
    private let terminal: CloudGatewayMacCLITerminal
    private let clock: CloudGatewayMacCLIClock
    private let output: (String) throws -> Void
    private let diagnostics: (String) -> Void
    private let connect: @MainActor () async throws -> CloudGatewayMacFrontendClient
    private let doctor: CloudGatewayMacCLIDoctor?
    private let loginEffects: CloudGatewayMacCLILoginEffects

    // The controller client is only created for commands that need it, after help, version, and usage checks
    public init(version: String, build: String, doctor: CloudGatewayMacCLIDoctor? = nil,
                loginEffects: CloudGatewayMacCLILoginEffects = .init(),
                connect: @escaping @MainActor () async throws -> CloudGatewayMacFrontendClient) {
        self.init(version: version, build: build, terminal: .current, clock: .continuous,
                  output: { try FileHandle.standardOutput.write(contentsOf: Data($0.utf8)) },
                  diagnostics: { try? FileHandle.standardError.write(contentsOf: Data($0.utf8)) },
                  doctor: doctor, loginEffects: loginEffects, connect: connect)
    }

    init(version: String, build: String, terminal: CloudGatewayMacCLITerminal, clock: CloudGatewayMacCLIClock,
         output: @escaping (String) throws -> Void, diagnostics: @escaping (String) -> Void,
         doctor: CloudGatewayMacCLIDoctor? = nil,
         loginEffects: CloudGatewayMacCLILoginEffects = .init(),
         connect: @escaping @MainActor () async throws -> CloudGatewayMacFrontendClient) {
        self.version = version
        self.build = build
        self.terminal = terminal
        self.clock = clock
        self.output = output
        self.diagnostics = diagnostics
        self.connect = connect
        self.doctor = doctor
        self.loginEffects = loginEffects
    }

    public func run(_ arguments: [String]) async -> Int32 {
        let invocation: CloudGatewayMacCLIInvocation
        do { invocation = try CloudGatewayMacCLIParser.parse(arguments) }
        catch {
            let failure = error as? CloudGatewayMacCLIUsageFailure
            return emit(command: failure?.command, .failure(.init(.usage, message: failure?.message)),
                        isJSON: arguments.contains { $0 == "--json" || $0.hasPrefix("--json=") }, isStyled: false)
        }
        let isStyled = terminal.allowsStyle(for: invocation)
        switch invocation.action {
        case .help(let topic):
            return emit(command: "help", .success(.help(.init(topic))), isJSON: invocation.isJSON, isStyled: isStyled)
        case .version:
            let version = CloudGatewayMacCLIVersion(version: CloudGatewayMacCLIText.sanitize(version),
                                                    build: CloudGatewayMacCLIText.sanitize(build))
            return emit(command: "version", .success(.version(version)),
                        isJSON: invocation.isJSON, isStyled: isStyled)
        case .run(let command):
            if command == .doctor, let doctor {
                return emit(command: command.name, await doctor.execute(timeout: invocation.timeout ?? .seconds(30)),
                            isJSON: invocation.isJSON, isStyled: isStyled)
            }
            if case .authLogin(let showsQR) = command {
                do {
                    let startedAt = clock.now()
                    let client = try await makeClient(until: startedAt + min(invocation.timeout ?? .seconds(30), .seconds(30)))
                    let runner = CloudGatewayMacCLILogin(client: client, clock: clock, terminal: terminal,
                                                        output: output, diagnostics: diagnostics, effects: loginEffects)
                    return emit(command: command.name, await runner.run(invocation: invocation, showsQR: showsQR, startedAt: startedAt),
                                isJSON: invocation.isJSON, isStyled: isStyled)
                } catch {
                    return emit(command: command.name, .failure(.init(error)),
                                isJSON: invocation.isJSON, isStyled: isStyled)
                }
            }
            let operationId: UUID? = if case .status(let id) = command { id } else { nil }
            let result = await execute(command, timeout: invocation.timeout) { id in
                let record = CloudGatewayMacCLIRecord(type: .accepted, command: command.name,
                                                      operationId: id.uuidString.lowercased())
                try output(invocation.isJSON ? record.line() : "Accepted operation \(id.uuidString.lowercased())\n")
            }
            return emit(command: command.name, operationId: operationId, result,
                        isJSON: invocation.isJSON, isStyled: isStyled)
        }
    }

    private func execute(_ command: CloudGatewayMacCLICommand,
                         timeout: Duration?, accepted: (UUID) throws -> Void) async -> Result<CloudGatewayMacCLIData, CloudGatewayMacCLIError> {
        let session: CloudGatewayMacCLISession
        switch command {
        case .authLogin, .doctor:
            return .failure(.init(.notImplemented, message: "`cloudgateway \(command.name)` is not available in this build yet"))
        default: break
        }
        let startedAt = clock.now()
        // Stop, Apple activation, 120s readiness, and reconnect outlast the usual wait
        let defaultTimeout: Duration = if case .update = command { .seconds(300) } else { .seconds(30) }
        let timeout = timeout ?? defaultTimeout
        do {
            let client = try await makeClient(until: startedAt + timeout)
            session = CloudGatewayMacCLISession(client: client, clock: clock, timeout: timeout, startedAt: startedAt)
        } catch { return .failure(.init(error)) }
        do {
            switch command {
            case .authStatus: return .success(try await session.authStatus())
            case .modeStatus: return .success(try await session.modeStatus())
            case .setMode(let mode): return .success(try await session.mutate(.setMode, mode: mode, accepted: accepted))
            case .status(let id?): return .success(try await session.operation(id))
            case .add(let region, let name): return .success(try await session.add(region: region, name: name, accepted: accepted))
            case .up(let selector): return .success(try await session.mutate(.connect, selector: selector, accepted: accepted))
            case .downTarget(let selector): return .success(try await session.mutate(.disconnectClient, selector: selector, accepted: accepted))
            case .remove(let selector): return .success(try await session.mutate(.removeClient, selector: selector, accepted: accepted))
            case .update(let allowDisconnect): return .success(try await session.update(allowDisconnect: allowDisconnect, accepted: accepted))
            case .down: return .success(try await session.mutate(.turnOff, accepted: accepted))
            case .authLogout: return .success(try await session.mutate(.signOut, accepted: accepted))
            case .refresh: return .success(try await session.refresh(regionId: nil, isList: false))
            case .list(let regionId, refresh: true, let long): return .success(try await session.refresh(regionId: regionId, isList: true, isLong: long))
            case .list(let regionId, _, let long): return .success(try await session.inventory(regionId: regionId, isLong: long))
            default: return .success(try await session.status())
            }
        } catch { return .failure(.init(error)) }
    }

    private func makeClient(until deadline: Duration) async throws -> CloudGatewayMacFrontendClient {
        try await CloudGatewayMacCLISession.call(clock: clock, deadline: deadline) {
            do { return try await connect() }
            catch is CancellationError { throw CancellationError() }
            catch { throw CloudGatewayMacCLIError(CloudGatewayMacCLIError.Code.untrustedBuild) }
        }
    }

    private func emit(command: String?, operationId: UUID? = nil,
                      _ result: Result<CloudGatewayMacCLIData, CloudGatewayMacCLIError>,
                      isJSON: Bool, isStyled: Bool) -> Int32 {
        let renderer = CloudGatewayMacCLIRenderer(isStyled: isStyled)
        var standardOutput = ""
        var standardError = ""
        var exitCode: Int32 = 0
        var record = CloudGatewayMacCLIRecord(type: .result, command: command,
                                              operationId: operationId?.uuidString.lowercased())
        switch result {
        case .success(let data):
            if case .mutation(let mutation) = data { record.operationId = mutation.operation.id }
            record.data = data
            standardOutput = renderer.render(data)
        case .failure(let error):
            exitCode = error.code.exitCode
            record.operationId = error.operationId?.uuidString.lowercased() ?? record.operationId
            record = .init(type: .error, command: command, operationId: record.operationId, data: error.data, error: .init(error))
            switch error.data {
            case .mutation(let mutation)? where error.code == .networkUnavailable && mutation.update == nil: break
            default: standardOutput = error.data.map(renderer.render) ?? ""
            }
            standardError = renderer.render(error)
        }
        if isJSON {
            do { standardOutput = try record.line() }
            catch {
                diagnostics("Error: CloudGateway could not encode its output\n")
                return 1
            }
            standardError = ""
        }
        do { if !standardOutput.isEmpty { try output(standardOutput) } }
        catch { return 1 }
        if !standardError.isEmpty { diagnostics(standardError) }
        return exitCode
    }
}
