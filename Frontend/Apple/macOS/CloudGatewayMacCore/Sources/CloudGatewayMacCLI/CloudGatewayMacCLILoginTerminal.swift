import Darwin
import Foundation

enum CloudGatewayMacCLILoginInterruption: Error, Equatable, Sendable {
    case cancelled, detached
}

@MainActor
protocol CloudGatewayMacCLILoginInput: AnyObject {
    var width: Int { get }
    var interruption: CloudGatewayMacCLILoginInterruption? { get }
    func start(shortcuts: Bool) -> Bool
    func readKeys() -> [UInt8]
    func close()
}

@MainActor
final class CloudGatewayMacCLILoginTerminal: CloudGatewayMacCLILoginInput {
    private var savedSettings: termios?
    private var savedFlags: Int32?
    private var savedSignals: [(Int32, sigaction)] = []
    private var signals: [any DispatchSourceSignal] = []
    private(set) var interruption: CloudGatewayMacCLILoginInterruption?

    var width: Int {
        var size = winsize()
        return ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &size) == 0 ? Int(size.ws_col) : 0
    }

    func start(shortcuts: Bool) -> Bool {
        for number in [SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGPIPE] {
            var previous = sigaction()
            var ignored = sigaction()
            ignored.__sigaction_u.__sa_handler = SIG_IGN
            sigemptyset(&ignored.sa_mask)
            guard sigaction(number, &ignored, &previous) == 0 else { continue }
            savedSignals.append((number, previous))
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                Task { @MainActor in
                    self?.interruption = number == SIGHUP || number == SIGPIPE ? .detached : .cancelled
                }
            }
            source.resume()
            signals.append(source)
        }
        guard shortcuts, isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1,
              tcgetpgrp(STDIN_FILENO) == getpgrp() else { return false }
        var settings = termios()
        guard tcgetattr(STDIN_FILENO, &settings) == 0 else { return false }
        let flags = fcntl(STDIN_FILENO, F_GETFL)
        guard flags >= 0 else { return false }
        savedSettings = settings
        savedFlags = flags
        settings.c_lflag &= ~tcflag_t(ICANON | ECHO)
        guard tcsetattr(STDIN_FILENO, TCSANOW, &settings) == 0,
              fcntl(STDIN_FILENO, F_SETFL, flags | O_NONBLOCK) == 0 else {
            restoreInput()
            return false
        }
        return true
    }

    func readKeys() -> [UInt8] {
        guard savedSettings != nil else { return [] }
        var bytes = [UInt8](repeating: 0, count: 64)
        let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
        if count > 0 {
            let keys = Array(bytes.prefix(count))
            if keys.contains(4) { restoreInput() }
            return keys.filter { $0 != 4 }
        }
        if count == 0 || (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) { restoreInput() }
        return []
    }

    private func restoreInput() {
        if var settings = savedSettings { _ = tcsetattr(STDIN_FILENO, TCSANOW, &settings) }
        if let flags = savedFlags { _ = fcntl(STDIN_FILENO, F_SETFL, flags) }
        savedSettings = nil
        savedFlags = nil
    }

    func close() {
        restoreInput()
        for source in signals { source.cancel() }
        signals = []
        for entry in savedSignals {
            var previous = entry.1
            _ = sigaction(entry.0, &previous, nil)
        }
        savedSignals = []
    }
}

enum CloudGatewayMacCLIQR {
    static func renderQR(_ matrix: [[Bool]], width: Int) -> String? {
        let count = matrix.count
        guard (21...177).contains(count), matrix.allSatisfy({ $0.count == count }), width >= count + 8 else { return nil }
        let quiet = [Bool](repeating: false, count: count + 8)
        let rows = Array(repeating: quiet, count: 4) + matrix.map {
            Array(repeating: false, count: 4) + $0 + Array(repeating: false, count: 4)
        } + Array(repeating: quiet, count: 4)
        var lines = [String]()
        for row in stride(from: 0, to: rows.count, by: 2) {
            let lower = row + 1 < rows.count ? rows[row + 1] : quiet
            lines.append(zip(rows[row], lower).map { upper, lower in
                switch (upper, lower) {
                case (true, true): "█"
                case (true, false): "▀"
                case (false, true): "▄"
                case (false, false): " "
                }
            }.joined())
        }
        return "\u{001B}[30;47m" + lines.joined(separator: "\n") + "\u{001B}[0m\n"
    }
}
