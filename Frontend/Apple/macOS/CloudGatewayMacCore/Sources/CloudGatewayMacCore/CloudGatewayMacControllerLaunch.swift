import Darwin
import Foundation

public enum CloudGatewayMacControllerLaunchError: Error, Equatable, Sendable {
    case busy
    case unsafeLocation
    case unavailable
    case installationRequired
}

public struct CloudGatewayMacControllerLauncher: Sendable {
    public static let serviceName = "com.gocloudlaunch.gateway.macos.controller"

    private let executableURL: URL
    private let directory: URL
    private let run: @Sendable (URL, [String]) async throws -> Int32

    public init(executableURL: URL, directory: URL) throws {
        let installedPath = "/Applications/CloudGateway.app/Contents/MacOS/CloudGateway"
        guard executableURL.path == installedPath,
              executableURL.resolvingSymlinksInPath().path == installedPath,
              FileManager.default.isExecutableFile(atPath: installedPath),
              Bundle(url: executableURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())?
                .bundleIdentifier == "com.gocloudlaunch.gateway.macos" else {
            throw CloudGatewayMacControllerLaunchError.installationRequired
        }
        try self.init(executableURL: executableURL, directory: directory, run: Self.runProcess)
    }

    init(
        executableURL: URL,
        directory: URL,
        run: @escaping @Sendable (URL, [String]) async throws -> Int32
    ) throws {
        try ControllerLaunchFiles.validateUser()
        try ControllerLaunchFiles.validateURL(executableURL)
        try ControllerLaunchFiles.validateURL(directory)
        self.executableURL = executableURL
        self.directory = directory
        self.run = run
    }

    // A false result is advisory, so callers must still retry the authenticated XPC handshake
    public func bootstrap() async throws -> Bool {
        try Task.checkCancellation()
        let directoryDescriptor = try ControllerLaunchFiles.openDirectory(directory)
        defer { close(directoryDescriptor) }
        let lock: Int32
        do {
            lock = try ControllerLaunchFiles.acquireLock(directory: directoryDescriptor, name: "controller-bootstrap.lock")
        } catch CloudGatewayMacControllerLaunchError.busy { return false }
        defer { close(lock) }

        let name = "\(Self.serviceName).plist"
        let plist: [String: Any] = [
            "Label": Self.serviceName,
            "ProgramArguments": [executableURL.path, "--controller"],
            "MachServices": [Self.serviceName: true],
            "LimitLoadToSessionType": "Background",
            "RunAtLoad": false,
            "ProcessType": "Background",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try ControllerLaunchFiles.writeAtomically(data, directory: directoryDescriptor, name: name)
        try Task.checkCancellation()
        do {
            let status = try await run(
                URL(fileURLWithPath: "/bin/launchctl"),
                ["bootstrap", "user/\(getuid())", directory.appendingPathComponent(name).path]
            )
            try Task.checkCancellation()
            return status == 0
        } catch is CancellationError { throw CancellationError() }
        catch { throw CloudGatewayMacControllerLaunchError.unavailable }
    }

    private static func runProcess(executableURL: URL, arguments: [String]) async throws -> Int32 {
        let pending = ControllerLaunchProcess()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending.start(executableURL: executableURL, arguments: arguments, continuation: continuation)
                Task {
                    try? await Task.sleep(for: .seconds(10))
                    pending.finish(.failure(CloudGatewayMacControllerLaunchError.unavailable))
                }
            }
        } onCancel: {
            pending.finish(.failure(CancellationError()))
        }
    }
}

private final class ControllerLaunchProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Int32, any Error>?
    private var result: Result<Int32, any Error>?

    func start(executableURL: URL, arguments: [String], continuation: CheckedContinuation<Int32, any Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
            return
        }
        self.continuation = continuation
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [self] process in
            finish(.success(process.terminationReason == .exit ? process.terminationStatus : -1))
        }
        do {
            try process.run()
            lock.unlock()
        } catch {
            lock.unlock()
            finish(.failure(CloudGatewayMacControllerLaunchError.unavailable))
        }
    }

    func finish(_ result: Result<Int32, any Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

// Retain this for the controller lifetime and acquire it before initializing Firebase
public final class CloudGatewayMacControllerOwnership: Sendable {
    private let descriptor: Int32

    // directory is the shared Application Support/CloudGateway/macOS directory across app versions
    public init(directory: URL) throws {
        let directoryDescriptor = try ControllerLaunchFiles.openDirectory(directory)
        defer { close(directoryDescriptor) }
        descriptor = try ControllerLaunchFiles.acquireLock(directory: directoryDescriptor, name: "controller-owner.lock")
    }

    deinit {
        // Keep the inode so another process cannot acquire a replacement while an owner still holds it
        close(descriptor)
    }
}

private enum ControllerLaunchFiles {
    static func validateUser() throws {
        guard getuid() != 0, geteuid() == getuid() else {
            throw CloudGatewayMacControllerLaunchError.unsafeLocation
        }
    }

    static func validateURL(_ url: URL) throws {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              url.path.hasPrefix("/"), !url.path.utf8.contains(0),
              !url.pathComponents.contains(".."), !url.pathComponents.contains(".") else {
            throw CloudGatewayMacControllerLaunchError.unsafeLocation
        }
    }

    static func openDirectory(_ url: URL) throws -> Int32 {
        try validateUser()
        try validateURL(url)
        let components = url.path.split(separator: "/").map(String.init)
        guard !components.isEmpty else { throw CloudGatewayMacControllerLaunchError.unsafeLocation }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw CloudGatewayMacControllerLaunchError.unavailable }
        do {
            for (index, component) in components.enumerated() {
                let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                let child: Int32
                if next >= 0 {
                    child = next
                } else {
                    guard errno == ENOENT else { throw locationError() }
                    if mkdirat(descriptor, component, 0o700) != 0, errno != EEXIST {
                        throw locationError()
                    }
                    child = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { throw locationError() }
                }
                close(descriptor)
                descriptor = child
                var info = stat()
                guard fstat(descriptor, &info) == 0 else { throw CloudGatewayMacControllerLaunchError.unavailable }
                let isPrivateDirectory = index == components.count - 1
                let isTrustedOwner = info.st_uid == getuid() || info.st_uid == 0
                let isWritableByOthers = info.st_mode & 0o022 != 0
                let isRootStickyDirectory = info.st_uid == 0 && info.st_mode & mode_t(S_ISVTX) != 0
                guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), isTrustedOwner,
                      !isWritableByOthers || isRootStickyDirectory,
                      !isPrivateDirectory || (info.st_uid == getuid() && info.st_mode & 0o7777 == 0o700) else {
                    throw CloudGatewayMacControllerLaunchError.unsafeLocation
                }
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    static func acquireLock(directory: Int32, name: String) throws -> Int32 {
        let descriptor = openat(directory, name, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { throw locationError() }
        do {
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { throw CloudGatewayMacControllerLaunchError.unavailable }
            try validateFile(info)
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                if errno == EWOULDBLOCK || errno == EAGAIN { throw CloudGatewayMacControllerLaunchError.busy }
                throw CloudGatewayMacControllerLaunchError.unavailable
            }
            var linkedInfo = stat()
            guard fstatat(directory, name, &linkedInfo, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw CloudGatewayMacControllerLaunchError.unsafeLocation
            }
            try validateFile(linkedInfo)
            guard linkedInfo.st_dev == info.st_dev, linkedInfo.st_ino == info.st_ino else {
                throw CloudGatewayMacControllerLaunchError.unsafeLocation
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    static func writeAtomically(_ data: Data, directory: Int32, name: String) throws {
        try validateDestination(directory: directory, name: name)
        let temporaryName = ".\(name).\(UUID().uuidString).tmp"
        let descriptor = openat(directory, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw locationError() }
        defer {
            close(descriptor)
            unlinkat(directory, temporaryName, 0)
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw CloudGatewayMacControllerLaunchError.unavailable }
        try validateFile(info)
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw CloudGatewayMacControllerLaunchError.unavailable }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw CloudGatewayMacControllerLaunchError.unavailable }
        try validateDestination(directory: directory, name: name)
        guard renameat(directory, temporaryName, directory, name) == 0 else { throw locationError() }
    }

    private static func validateDestination(directory: Int32, name: String) throws {
        var info = stat()
        guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return }
            throw locationError()
        }
        try validateFile(info)
    }

    private static func validateFile(_ info: stat) throws {
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_uid == getuid(),
              info.st_nlink == 1, info.st_mode & 0o7777 == 0o600 else {
            throw CloudGatewayMacControllerLaunchError.unsafeLocation
        }
    }

    private static func locationError() -> CloudGatewayMacControllerLaunchError {
        errno == ELOOP || errno == ENOTDIR ? .unsafeLocation : .unavailable
    }
}
