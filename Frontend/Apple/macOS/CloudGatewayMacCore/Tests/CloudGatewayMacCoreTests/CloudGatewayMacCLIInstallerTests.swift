import Foundation
import Testing
@testable import CloudGatewayMacCore

@Test func cliInstallerCreatesOnlyALinkAndRecognizesRepeatInstallation() throws {
    let fixture = try CLIInstallerFixture()
    defer { fixture.cleanup() }
    var validations = 0
    #expect(try fixture.installer.install(runningBundleURL: fixture.app) { validations += 1 } == .installed)
    #expect(try fixture.installer.install(runningBundleURL: fixture.app) { validations += 1 } == .alreadyInstalled)
    #expect(validations == 2)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.installer.executableURL.path) == fixture.binary.path)
    #expect(try Data(contentsOf: fixture.binary) == Data("fixture".utf8))
    #expect(!FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent(".zprofile").path))
}

@Test func cliInstallerRejectsOtherAppLocationsBeforeChangingHome() throws {
    let fixture = try CLIInstallerFixture()
    defer { fixture.cleanup() }
    for path in ["/Volumes/CloudGateway/CloudGateway.app", "/private/var/folders/AppTranslocation/CloudGateway.app",
                 "/tmp/DerivedData/CloudGateway.app"] {
        #expect(throws: CloudGatewayMacCLIInstallError.installationRequired) {
            try fixture.installer.install(runningBundleURL: URL(fileURLWithPath: path)) {
                Issue.record("Unexpected installed-app validation")
            }
        }
    }
    #expect(throws: CloudGatewayMacCLIInstallError.invalidInstalledApp) {
        try fixture.installer.install(runningBundleURL: fixture.app) { throw CocoaError(.fileReadCorruptFile) }
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent(".local").path))
}

@Test func cliInstallerPreservesFilesDirectoriesAndLinks() throws {
    for kind in ["file", "directory", "link", "broken"] {
        let fixture = try CLIInstallerFixture()
        defer { fixture.cleanup() }
        let link = fixture.installer.executableURL
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        let expected: CloudGatewayMacCLIInstallError
        switch kind {
        case "file":
            try Data("keep".utf8).write(to: link)
            expected = .conflictingFile
        case "directory":
            try FileManager.default.createDirectory(at: link, withIntermediateDirectories: false)
            expected = .conflictingFile
        default:
            let target = fixture.root.appendingPathComponent(kind == "link" ? "other" : "missing")
            if kind == "link" { try Data("keep".utf8).write(to: target) }
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            expected = kind == "link" ? .conflictingLink : .brokenLink
        }
        #expect(throws: expected) { try fixture.installer.install(runningBundleURL: fixture.app) {} }
        let attributes = try FileManager.default.attributesOfItem(atPath: link.path)
        #expect(attributes[.type] as? FileAttributeType == (kind == "file" ? .typeRegular : kind == "directory" ? .typeDirectory : .typeSymbolicLink))
        if kind == "file" { #expect(try String(contentsOf: link, encoding: .utf8) == "keep") }
    }
}

@Test func cliInstallerRejectsLinkedOrWritableDirectoriesAndLinkedApps() throws {
    let fixture = try CLIInstallerFixture()
    defer { fixture.cleanup() }
    let local = fixture.home.appendingPathComponent(".local")
    try FileManager.default.createSymbolicLink(at: local, withDestinationURL: fixture.root)
    #expect(throws: CloudGatewayMacCLIInstallError.unsafeDirectory) {
        try fixture.installer.install(runningBundleURL: fixture.app) {}
    }
    let alias = fixture.root.appendingPathComponent("CloudGatewayAlias.app")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.app)
    let aliasInstaller = CloudGatewayMacCLIInstaller(homeURL: fixture.home, installedAppURL: alias)
    #expect(throws: CloudGatewayMacCLIInstallError.installationRequired) {
        try aliasInstaller.install(runningBundleURL: alias) {}
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: fixture.home.path)
    #expect(throws: CloudGatewayMacCLIInstallError.unsafeDirectory) {
        try fixture.installer.install(runningBundleURL: fixture.app) {}
    }
}

@Test func cliInstallerFollowsAppReplacementWithoutRewritingTheLink() throws {
    let fixture = try CLIInstallerFixture()
    defer { fixture.cleanup() }
    #expect(try fixture.installer.install(runningBundleURL: fixture.app) {} == .installed)
    let previous = fixture.root.appendingPathComponent("previous.app")
    try FileManager.default.moveItem(at: fixture.app, to: previous)
    #expect(!FileManager.default.fileExists(atPath: fixture.installer.executableURL.path))
    #expect(throws: CloudGatewayMacCLIInstallError.invalidInstalledApp) {
        try fixture.installer.install(runningBundleURL: fixture.app) {}
    }
    try FileManager.default.moveItem(at: previous, to: fixture.app)
    try Data("replacement".utf8).write(to: fixture.binary)
    #expect(try fixture.installer.install(runningBundleURL: fixture.app) {} == .alreadyInstalled)
    #expect(try Data(contentsOf: fixture.installer.executableURL) == Data("replacement".utf8))
}

@Test func cliInstallerRejectsLinkedHomeAndBinWithoutWritingThroughThem() throws {
    let fixture = try CLIInstallerFixture()
    defer { fixture.cleanup() }
    let alias = fixture.root.appendingPathComponent("home-alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.home)
    let aliasInstaller = CloudGatewayMacCLIInstaller(homeURL: alias, installedAppURL: fixture.app)
    #expect(throws: CloudGatewayMacCLIInstallError.unsafeDirectory) {
        try aliasInstaller.install(runningBundleURL: fixture.app) {}
    }
    let local = fixture.home.appendingPathComponent(".local")
    try FileManager.default.createDirectory(at: local, withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(at: local.appendingPathComponent("bin"), withDestinationURL: fixture.root)
    #expect(throws: CloudGatewayMacCLIInstallError.unsafeDirectory) {
        try fixture.installer.install(runningBundleURL: fixture.app) {}
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("cloudgateway").path))
}

@Test func cliInstallerPathEditPreservesContentsModeAndAvoidsDuplicates() throws {
    let fixture = try CLIInstallerFixture()
    defer { fixture.cleanup() }
    let profile = fixture.home.appendingPathComponent(".zprofile")
    try Data("# existing setup\nexport EDITOR=vi".utf8).write(to: profile)
    try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: profile.path)
    #expect(try fixture.installer.addToZshPath(shell: "/bin/zsh", environment: [:]) == .added)
    let expected = "# existing setup\nexport EDITOR=vi\nexport PATH=\"$HOME/.local/bin:$PATH\"\n"
    #expect(try String(contentsOf: profile, encoding: .utf8) == expected)
    #expect(try (FileManager.default.attributesOfItem(atPath: profile.path)[.posixPermissions] as? NSNumber)?.intValue == 0o640)
    #expect(try fixture.installer.addToZshPath(shell: "/bin/zsh", environment: [:]) == .alreadyConfigured(file: ".zprofile"))
    #expect(try String(contentsOf: profile, encoding: .utf8) == expected)
}

@Test func cliInstallerPathEditCreatesPrivateStartupFile() throws {
    let fixture = try CLIInstallerFixture()
    defer { fixture.cleanup() }
    #expect(try fixture.installer.addToZshPath(shell: "/bin/zsh", environment: [:]) == .added)
    let profile = fixture.home.appendingPathComponent(".zprofile")
    #expect(try (FileManager.default.attributesOfItem(atPath: profile.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}

@Test func cliInstallerPathEditLeavesCustomShellConfigurationAlone() throws {
    let fixture = try CLIInstallerFixture()
    defer { fixture.cleanup() }
    for (shell, environment) in [("/bin/bash", [:]), ("/bin/zsh", ["ZDOTDIR": "/custom"]), ("/bin/zsh", ["ZDOTDIR": ""])] {
        #expect(throws: CloudGatewayMacCLIInstallError.manualShellConfiguration) {
            try fixture.installer.addToZshPath(shell: shell, environment: environment)
        }
    }
    let profile = fixture.home.appendingPathComponent(".zprofile")
    #expect(!FileManager.default.fileExists(atPath: profile.path))
    try Data("export PATH=\"/custom:$PATH\"\n".utf8).write(to: profile)
    #expect(throws: CloudGatewayMacCLIInstallError.manualShellConfiguration) {
        try fixture.installer.addToZshPath(shell: "/bin/zsh", environment: [:])
    }
    #expect(try String(contentsOf: profile, encoding: .utf8) == "export PATH=\"/custom:$PATH\"\n")
    try Data().write(to: fixture.home.appendingPathComponent(".zshenv"))
    #expect(throws: CloudGatewayMacCLIInstallError.manualShellConfiguration) {
        try fixture.installer.addToZshPath(shell: "/bin/zsh", environment: [:])
    }
}

@Test func cliInstallerPathEditRejectsLinkedSharedAndNonregularStartupFiles() throws {
    for kind in ["symlink", "broken", "hardlink", "directory", "writable", "invalid"] {
        let fixture = try CLIInstallerFixture()
        defer { fixture.cleanup() }
        let profile = fixture.home.appendingPathComponent(".zprofile")
        let target = fixture.root.appendingPathComponent("startup")
        try Data("keep".utf8).write(to: target)
        switch kind {
        case "symlink": try FileManager.default.createSymbolicLink(at: profile, withDestinationURL: target)
        case "broken": try FileManager.default.createSymbolicLink(at: profile, withDestinationURL: fixture.root.appendingPathComponent("missing"))
        case "hardlink": try FileManager.default.linkItem(at: target, to: profile)
        case "directory": try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: false)
        case "writable":
            try Data("keep".utf8).write(to: profile)
            try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: profile.path)
        default: try Data([0xff]).write(to: profile)
        }
        #expect(throws: CloudGatewayMacCLIInstallError.unsafeStartupFile) {
            try fixture.installer.addToZshPath(shell: "/bin/zsh", environment: [:])
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "keep")
    }
}

@Test func cliInstallerPathEditRejectsShellCodeAndHomeOverridesWithoutChangingThem() throws {
    let fixture = try CLIInstallerFixture()
    defer { fixture.cleanup() }
    let profile = fixture.home.appendingPathComponent(".zprofile")
    for contents in ["source ~/.shell-setup\n", "if true; then\n", "export EDITOR='unfinished\n",
                     "export HOME=/custom\n", "export ZDOTDIR=/custom\n", "export path=/custom\n"] {
        try Data(contents.utf8).write(to: profile)
        #expect(throws: CloudGatewayMacCLIInstallError.manualShellConfiguration) {
            try fixture.installer.addToZshPath(shell: "/bin/zsh", environment: [:])
        }
        #expect(try String(contentsOf: profile, encoding: .utf8) == contents)
    }
}

@Test func cliInstallerPathEditRejectsOverridesAfterManagedLine() throws {
    let fixture = try CLIInstallerFixture()
    defer { fixture.cleanup() }
    let profile = fixture.home.appendingPathComponent(".zprofile")
    let managed = "export PATH=\"$HOME/.local/bin:$PATH\"\n"
    for contents in [managed + "export PATH=/usr/bin\n", managed + "path=(/usr/bin)\n"] {
        try Data(contents.utf8).write(to: profile)
        #expect(throws: CloudGatewayMacCLIInstallError.manualShellConfiguration) {
            try fixture.installer.addToZshPath(shell: "/bin/zsh", environment: [:])
        }
        #expect(try String(contentsOf: profile, encoding: .utf8) == contents)
    }
}

@Test func cliInstallerRecognizesEnvironmentPathBeforeInspectingShellFiles() throws {
    let fixture = try CLIInstallerFixture()
    defer { fixture.cleanup() }
    let bin = fixture.installer.executableURL.deletingLastPathComponent().path
    try Data("keep".utf8).write(to: fixture.home.appendingPathComponent(".zshenv"))
    #expect(try fixture.installer.addToZshPath(shell: "/bin/bash", environment: [
        "PATH": "/usr/bin:\(bin)/:/bin", "ZDOTDIR": "/custom"
    ]) == .alreadyOnPath)
    #expect(!FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent(".zprofile").path))
    #expect(!FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent(".zshrc").path))
}

@Test func cliInstallerEnvironmentPathRequiresWholeDirectory() throws {
    let fixture = try CLIInstallerFixture()
    defer { fixture.cleanup() }
    let bin = fixture.installer.executableURL.deletingLastPathComponent().path
    #expect(try fixture.installer.addToZshPath(shell: "/bin/zsh", environment: ["PATH": "\(bin)-other:/usr/bin"]) == .added)
}

@Test(arguments: [
    "export PATH=\"$HOME/.local/bin:$PATH\"",
    "PATH=\"$PATH:${HOME}/.local/bin\" # CLI tools",
    "export PATH=$HOME/.local/bin:$PATH",
    "PATH=~/.local/bin:$PATH",
    "PATH+=:$HOME/.local/bin/",
    "PATH+=/other:$HOME/.local/bin",
    "path=(\"$HOME/.local/bin\" $path)",
    "path+=(~/.local/bin)",
    "path=(\"/other bin\" \"$HOME/.local/bin\" $path)",
    "export path=(${HOME}/.local/bin $path)",
    "PATH=\"$HOME/.local/bin:$PATH\"\nexport PATH=\"$PATH:/opt/homebrew/bin\"",
    "PATH=\"$HOME/.local/bin:$PATH\"\nPATH+=:/opt/homebrew/bin",
    "PATH=\"$HOME/.local/bin:$PATH\"\npath=($path /opt/homebrew/bin)",
    "path=(~/.local/bin $path)\npath+=(/opt/homebrew/bin)"
])
func cliInstallerRecognizesStartupPathWithoutChangingFiles(line: String) throws {
    for name in [".zshrc", ".zprofile"] {
        let fixture = try CLIInstallerFixture()
        defer { fixture.cleanup() }
        let file = fixture.home.appendingPathComponent(name)
        let contents = "# custom shell setup\nsource ~/.shell-config\n\(line)\n"
        try Data(contents.utf8).write(to: file)
        #expect(try fixture.installer.addToZshPath(shell: "/bin/zsh", environment: [:]) == .alreadyConfigured(file: name))
        #expect(try String(contentsOf: file, encoding: .utf8) == contents)
        let other = fixture.home.appendingPathComponent(name == ".zshrc" ? ".zprofile" : ".zshrc")
        #expect(!FileManager.default.fileExists(atPath: other.path))
    }
}

@Test func cliInstallerRecognizesAbsoluteAndLinkedStartupConfiguration() throws {
    let fixture = try CLIInstallerFixture()
    defer { fixture.cleanup() }
    let target = fixture.root.appendingPathComponent("zshrc")
    let bin = fixture.installer.executableURL.deletingLastPathComponent().path
    let contents = "export PATH='\(bin):/usr/bin'\n"
    try Data(contents.utf8).write(to: target)
    try Data("# existing environment setup\n".utf8).write(to: fixture.home.appendingPathComponent(".zshenv"))
    let rc = fixture.home.appendingPathComponent(".zshrc")
    try FileManager.default.createSymbolicLink(at: rc, withDestinationURL: target)
    #expect(try fixture.installer.addToZshPath(shell: "/bin/zsh", environment: [:]) == .alreadyConfigured(file: ".zshrc"))
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: rc.path) == target.path)
    #expect(try String(contentsOf: target, encoding: .utf8) == contents)
    #expect(!FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent(".zprofile").path))
}

@Test(arguments: [
    "# export PATH=\"$HOME/.local/bin:$PATH\"",
    "echo '$HOME/.local/bin'",
    "export PATH='$HOME/.local/bin:/usr/bin'",
    "export PATH=\"~/.local/bin:$PATH\"",
    "export PATH=\"$HOME/.local/bin-other:$PATH\"",
    "export PATH=\"$PATH:$HOME/.local/bin",
    "path=(\"\\$HOME/.local/bin\" $path)",
    "PATH=/usr/bin:/bin\nPATH+=\"$HOME/.local/bin\"",
    "path=(\"$HOME/.local/bin\"-other $path)",
    "path=($HOME/.local/bin\"-other\" $path)",
    "path=(\"prefix $HOME/.local/bin suffix\"-other /usr/bin /bin)",
    "path=(\"prefix $HOME/.local/bin suffix $path)",
    "export PATH=\"$HOME/.local/bin\"#old",
    "export PATH=\"$(printf '%s' '/usr/bin:$HOME/.local/bin:/bin')\"",
    "export PATH=\"`printf '%s' '/usr/bin:$HOME/.local/bin:/bin'`\"",
    "export PATH=\"${PATH:-/usr/bin:$HOME/.local/bin:/bin}\"",
    "PATH=\"$HOME/.local/bin\"\nPATH=\"$PATH:h\"",
    "path=(${OTHER:-prefix $HOME/.local/bin suffix} $path)",
    "path=($path # $HOME/.local/bin)"
])
func cliInstallerIgnoresUnexpandedPathsCommentsAndSimilarDirectories(line: String) throws {
    let fixture = try CLIInstallerFixture()
    defer { fixture.cleanup() }
    let rc = fixture.home.appendingPathComponent(".zshrc")
    try Data(line.utf8).write(to: rc)
    #expect(try fixture.installer.addToZshPath(shell: "/bin/zsh", environment: [:]) == .added)
    #expect(try String(contentsOf: rc, encoding: .utf8) == line)
}

@Test func cliInstallerRecognizesFinalConfiguredAssignmentAndAvoidsAddingMoreDuplicates() throws {
    let fixture = try CLIInstallerFixture()
    defer { fixture.cleanup() }
    let profile = fixture.home.appendingPathComponent(".zprofile")
    let managed = "export PATH=\"$HOME/.local/bin:$PATH\"\n"
    for contents in ["export PATH=/usr/bin\n" + managed, managed + managed] {
        try Data(contents.utf8).write(to: profile)
        #expect(try fixture.installer.addToZshPath(shell: "/bin/zsh", environment: [:]) == .alreadyConfigured(file: ".zprofile"))
        #expect(try String(contentsOf: profile, encoding: .utf8) == contents)
    }
}

private struct CLIInstallerFixture {
    let root: URL
    let home: URL
    let app: URL
    let binary: URL
    let installer: CloudGatewayMacCLIInstaller

    init() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("CloudGatewayInstaller-\(UUID())")
        home = root.appendingPathComponent("home")
        app = root.appendingPathComponent("Applications/CloudGateway.app")
        binary = app.appendingPathComponent("Contents/MacOS/CloudGateway")
        installer = CloudGatewayMacCLIInstaller(homeURL: home, installedAppURL: app)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}
