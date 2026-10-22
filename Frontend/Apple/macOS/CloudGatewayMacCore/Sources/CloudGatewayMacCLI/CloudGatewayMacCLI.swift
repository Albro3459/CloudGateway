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
    private let connect: @MainActor () throws -> CloudGatewayMacFrontendClient

    // The controller client is only created for commands that need it, after help, version, and usage checks
    public init(version: String, build: String, connect: @escaping @MainActor () throws -> CloudGatewayMacFrontendClient) {
        self.init(version: version, build: build, terminal: .current, clock: .continuous,
                  output: { try FileHandle.standardOutput.write(contentsOf: Data($0.utf8)) },
                  diagnostics: { try? FileHandle.standardError.write(contentsOf: Data($0.utf8)) },
                  connect: connect)
    }

    init(version: String, build: String, terminal: CloudGatewayMacCLITerminal, clock: CloudGatewayMacCLIClock,
         output: @escaping (String) throws -> Void, diagnostics: @escaping (String) -> Void,
         connect: @escaping @MainActor () throws -> CloudGatewayMacFrontendClient) {
        self.version = version
        self.build = build
        self.terminal = terminal
        self.clock = clock
        self.output = output
        self.diagnostics = diagnostics
        self.connect = connect
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
            let operationId: UUID? = if case .status(let id) = command { id } else { nil }
            return emit(command: command.name, operationId: operationId, await execute(command, timeout: invocation.timeout),
                        isJSON: invocation.isJSON, isStyled: isStyled)
        }
    }

    private func execute(_ command: CloudGatewayMacCLICommand,
                         timeout: Duration?) async -> Result<CloudGatewayMacCLIData, CloudGatewayMacCLIError> {
        let session: CloudGatewayMacCLISession
        switch command {
        case .authStatus, .status, .list(_, refresh: false): break
        case .authLogin, .authLogout, .list(_, refresh: true), .up, .down, .refresh, .doctor:
            return .failure(.init(.notImplemented, message: "`cloudgateway \(command.name)` is not available in this build yet"))
        }
        do { session = CloudGatewayMacCLISession(client: try connect(), clock: clock, timeout: timeout ?? .seconds(30)) }
        catch { return .failure(.init(.untrustedBuild)) }
        do {
            switch command {
            case .authStatus: return .success(try await session.authStatus())
            case .status(let id?): return .success(try await session.operation(id))
            case .list(let regionId, _): return .success(try await session.inventory(regionId: regionId))
            default: return .success(try await session.status())
            }
        } catch { return .failure(.init(error)) }
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
            record.data = data
            standardOutput = renderer.render(data)
        case .failure(let error):
            exitCode = error.code.exitCode
            record = .init(type: .error, command: command, operationId: record.operationId, data: error.data, error: .init(error))
            standardOutput = error.data.map(renderer.render) ?? ""
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
