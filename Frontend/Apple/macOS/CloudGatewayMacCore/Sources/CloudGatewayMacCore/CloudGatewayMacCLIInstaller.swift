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
        case added, alreadyOnPath, alreadyConfigured(file: String)
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
        let binPath = executableURL.deletingLastPathComponent().path
        if environment["PATH"]?.split(separator: ":").contains(where: {
            $0.hasPrefix("/") && URL(fileURLWithPath: String($0)).standardizedFileURL.path == binPath
        }) == true { return .alreadyOnPath }
        guard shell == "/bin/zsh", environment["ZDOTDIR"] == nil else {
            throw CloudGatewayMacCLIInstallError.manualShellConfiguration
        }
        let home = try openHome()
        defer { close(home) }
        for name in [".zshrc", ".zprofile"] {
            if try startupFileIncludesBin(name, in: home) { return .alreadyConfigured(file: name) }
        }
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

    private func startupFileIncludesBin(_ name: String, in home: Int32) throws -> Bool {
        // Follow startup-file links for inspection only, never for editing
        let file = openat(home, name, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        if file < 0, errno == ENOENT { return false }
        guard file >= 0 else { throw CloudGatewayMacCLIInstallError.unsafeStartupFile }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_uid == getuid(), info.st_mode & 0o022 == 0, info.st_size <= 1_048_576 else {
            throw CloudGatewayMacCLIInstallError.unsafeStartupFile
        }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        let count = bytes.withUnsafeMutableBytes { read(file, $0.baseAddress, $0.count) }
        guard count == bytes.count, let contents = String(bytes: bytes, encoding: .utf8), !contents.contains("\0") else {
            throw CloudGatewayMacCLIInstallError.unsafeStartupFile
        }
        let assignments = contents.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.range(of: "^(export[ \\t]+)?(PATH|path)\\+?=", options: .regularExpression) != nil }
        var includesBin = false
        for assignment in assignments { includesBin = try assignmentIncludesBin(assignment, retaining: includesBin) }
        return includesBin
    }

    private func assignmentIncludesBin(_ last: String, retaining existing: Bool) throws -> Bool {
        let range = NSRange(last.startIndex..., in: last)
        let assignment = try NSRegularExpression(pattern: #"^(?:export[ \t]+)?PATH\+?=(?:"([^"]*)"|'([^']*)'|([^ \t"'\\;#]+))(?:[ \t]+#.*)?[ \t]*$"#)
        if let match = assignment.firstMatch(in: last, range: range) {
            let appending = last.range(of: #"^(?:export[ \t]+)?PATH\+="#, options: .regularExpression) != nil
            for index in 1...3 {
                guard let range = Range(match.range(at: index), in: last) else { continue }
                let value = String(last[range])
                guard value.rangeOfCharacter(from: CharacterSet(charactersIn: "\\`()")) == nil,
                      hasSupportedPathVariables(value) else { return false }
                let components = value.split(separator: ":", omittingEmptySubsequences: false)
                let includesBin = components.dropFirst(appending ? 1 : 0).contains {
                    isBinPath(String($0), expandHome: index != 2, expandTilde: index == 3)
                }
                let retains = appending ? value.hasPrefix(":") : index != 2 && components.contains { ["$PATH", "${PATH}"].contains($0) }
                return includesBin || existing && retains
            }
        }
        let array = try NSRegularExpression(pattern: #"^(?:export[ \t]+)?path\+?=\(([^()#;\\`]+)\)(?:[ \t]+#.*)?[ \t]*$"#)
        guard let match = array.firstMatch(in: last, range: range),
              let range = Range(match.range(at: 1), in: last),
              hasSupportedPathVariables(String(last[range])) else { return false }
        var words: [String] = []
        var word = ""
        var quote: Character?
        for character in last[range] {
            if let current = quote {
                word.append(character)
                if character == current { quote = nil }
            } else if character == "\"" || character == "'" {
                word.append(character)
                quote = character
            } else if character.isWhitespace {
                if !word.isEmpty { words.append(word); word = "" }
            } else { word.append(character) }
        }
        guard quote == nil else { return false }
        if !word.isEmpty { words.append(word) }
        let includesBin = words.contains { word in
            if word.hasPrefix("\""), word.hasSuffix("\"") {
                return isBinPath(String(word.dropFirst().dropLast()), expandHome: true, expandTilde: false)
            }
            if word.hasPrefix("'"), word.hasSuffix("'") {
                return isBinPath(String(word.dropFirst().dropLast()), expandHome: false, expandTilde: false)
            }
            return isBinPath(word, expandHome: true, expandTilde: true)
        }
        let appending = last.range(of: #"^(?:export[ \t]+)?path\+="#, options: .regularExpression) != nil
        return includesBin || existing && (appending || words.contains { ["$path", "${path}"].contains($0) })
    }

    private func hasSupportedPathVariables(_ value: String) -> Bool {
        guard value.range(of: #"\$(?:HOME|PATH|path):[A-Za-z0-9_&]"#, options: .regularExpression) == nil else { return false }
        return !value.replacingOccurrences(of: #"\$(?:HOME|PATH|path)(?![A-Za-z0-9_])|\$\{(?:HOME|PATH|path)\}"#,
                                          with: "", options: .regularExpression).contains("$")
    }

    private func isBinPath(_ value: String, expandHome: Bool, expandTilde: Bool) -> Bool {
        let path = value.hasSuffix("/") ? String(value.dropLast()) : value
        if path == executableURL.deletingLastPathComponent().path { return true }
        if expandHome, ["$HOME/.local/bin", "${HOME}/.local/bin"].contains(path) { return true }
        return expandTilde && path == "~/.local/bin"
    }

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
