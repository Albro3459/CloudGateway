@MainActor
public final class CloudGatewayMacPassiveRuntime<Runtime> {
    public private(set) var initialized: Runtime?
    private let create: () -> Runtime

    public init(create: @escaping () -> Runtime) {
        self.create = create
    }

    public func require() -> Runtime {
        if let initialized { return initialized }
        let runtime = create()
        initialized = runtime
        return runtime
    }
}
