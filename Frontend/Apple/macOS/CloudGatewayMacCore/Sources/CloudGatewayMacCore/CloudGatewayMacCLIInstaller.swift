import Darwin
import Foundation

public enum CloudGatewayMacCLIInstallError: Error, Equatable {
    case installationRequired, invalidInstalledApp, unsafeDirectory, conflictingFile, conflictingLink, brokenLink
    case manualShellConfiguration, unsafeStartupFile, filesystemFailure
}

public struct CloudGatewayMacCLIInstaller {
    public enum Result: Equatable {
        case installed, alreadyInstalled
    }

    public enum PathResult: Equatable {
        case added, alreadyConfigured
    }

    private let homeURL: URL
    private let installedAppURL: URL

    public init(homeURL: URL) {
        self.init(homeURL: homeURL, installedAppURL: URL(fileURLWithPath: "/Applications/CloudGateway.app"))
    }

    init(homeURL: URL, installedAppURL: URL) {
        self.homeURL = homeURL
        self.installedAppURL = installedAppURL
    }

    public var executableURL: URL { homeURL.appendingPathComponent(".local/bin/cloudgateway") }

    public func install(runningBundleURL: URL, validateInstalledApp: () throws -> Void) throws -> Result {
        guard runningBundleURL.path == installedAppURL.path,
              runningBundleURL.resolvingSymlinksInPath().path == installedAppURL.path else {
            throw CloudGatewayMacCLIInstallError.installationRequired
        }
        do { try validateInstalledApp() }
        catch { throw CloudGatewayMacCLIInstallError.invalidInstalledApp }
        let target = installedAppURL.appendingPathComponent("Contents/MacOS/CloudGateway")
        var info = stat()
        guard lstat(target.path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              access(target.path, X_OK) == 0 else {
            throw CloudGatewayMacCLIInstallError.invalidInstalledApp
        }
        let home = try openHome()
        defer { close(home) }
        let local = try directory(".local", in: home)
        defer { close(local) }
        let bin = try directory("bin", in: local)
        defer { close(bin) }
        if symlinkat(target.path, bin, "cloudgateway") == 0 { return .installed }
        guard errno == EEXIST else { throw CloudGatewayMacCLIInstallError.filesystemFailure }
        guard fstatat(bin, "cloudgateway", &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw CloudGatewayMacCLIInstallError.filesystemFailure
        }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) else { throw CloudGatewayMacCLIInstallError.conflictingFile }
        var bytes = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = readlinkat(bin, "cloudgateway", &bytes, Int(PATH_MAX))
        guard count > 0, count < Int(PATH_MAX) else { throw CloudGatewayMacCLIInstallError.conflictingLink }
        guard fstatat(bin, "cloudgateway", &info, 0) == 0 else {
            throw CloudGatewayMacCLIInstallError.brokenLink
        }
        guard String(decoding: bytes.prefix(count).map { UInt8(bitPattern: $0) }, as: UTF8.self) == target.path else {
            throw CloudGatewayMacCLIInstallError.conflictingLink
        }
        return .alreadyInstalled
    }

    public func addToZshPath(shell: String?, environment: [String: String]) throws -> PathResult {
        guard shell == "/bin/zsh", environment["ZDOTDIR"] == nil else {
            throw CloudGatewayMacCLIInstallError.manualShellConfiguration
        }
        let home = try openHome()
        defer { close(home) }
        // A zshenv can redirect startup files before zprofile is read
        var info = stat()
        guard fstatat(home, ".zshenv", &info, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else {
            throw CloudGatewayMacCLIInstallError.manualShellConfiguration
        }
        let file = openat(home, ".zprofile", O_RDWR | O_APPEND | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw CloudGatewayMacCLIInstallError.unsafeStartupFile }
        defer { close(file) }
        guard flock(file, LOCK_EX | LOCK_NB) == 0 else { throw CloudGatewayMacCLIInstallError.unsafeStartupFile }
        defer { flock(file, LOCK_UN) }
        guard fstat(file, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_uid == getuid(), info.st_mode & 0o022 == 0, info.st_nlink == 1,
              info.st_size <= 1_048_576 else {
            throw CloudGatewayMacCLIInstallError.unsafeStartupFile
        }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        let count = bytes.withUnsafeMutableBytes { read(file, $0.baseAddress, $0.count) }
        guard count == bytes.count, let contents = String(bytes: bytes, encoding: .utf8), !contents.contains("\0") else {
            throw CloudGatewayMacCLIInstallError.unsafeStartupFile
        }
        let activeLines = contents.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard activeLines.allSatisfy({ line in
            !line.hasPrefix("export HOME=") && !line.hasPrefix("export ZDOTDIR=")
                && (line == Self.pathLine || line.range(of: "^export [A-Za-z_][A-Za-z0-9_]*=[A-Za-z0-9_./-]*$", options: .regularExpression) != nil)
        }) else { throw CloudGatewayMacCLIInstallError.manualShellConfiguration }
        let pathLines = activeLines.filter { line in
            line.contains("PATH") || line.contains("path=") || line.contains("path=(")
        }
        if !pathLines.isEmpty {
            if pathLines == [Self.pathLine] { return .alreadyConfigured }
            // Do not infer the meaning of existing shell code or duplicate its PATH changes
            throw CloudGatewayMacCLIInstallError.manualShellConfiguration
        }
        let addition = (contents.isEmpty || contents.hasSuffix("\n") ? "" : "\n") + Self.pathLine + "\n"
        let data = Data(addition.utf8)
        let written = data.withUnsafeBytes { write(file, $0.baseAddress, $0.count) }
        guard written == data.count, fsync(file) == 0 else { throw CloudGatewayMacCLIInstallError.filesystemFailure }
        return .added
    }

    private static let pathLine = "export PATH=\"$HOME/.local/bin:$PATH\""

    private func openHome() throws -> Int32 {
        guard getuid() != 0, homeURL.isFileURL, homeURL.path.hasPrefix("/"),
              !homeURL.pathComponents.contains("..") else { throw CloudGatewayMacCLIInstallError.unsafeDirectory }
        let file = open(homeURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { throw CloudGatewayMacCLIInstallError.unsafeDirectory }
        do { try validateDirectory(file) }
        catch { close(file); throw error }
        return file
    }

    private func directory(_ name: String, in parent: Int32) throws -> Int32 {
        guard mkdirat(parent, name, 0o755) == 0 || errno == EEXIST else {
            throw CloudGatewayMacCLIInstallError.filesystemFailure
        }
        let file = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { throw CloudGatewayMacCLIInstallError.unsafeDirectory }
        do { try validateDirectory(file) }
        catch { close(file); throw error }
        return file
    }

    private func validateDirectory(_ file: Int32) throws {
        var info = stat()
        guard fstat(file, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o022 == 0 else {
            throw CloudGatewayMacCLIInstallError.unsafeDirectory
        }
    }
}
