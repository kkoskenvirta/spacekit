import Darwin
import Foundation
import SpaceKitCore

/// Raw-mode terminal I/O for the full-screen interface.
public final class Terminal {
    private var isRaw = false
    /// Seconds to wait for the rest of a key sequence the terminal split across reads.
    private static let sequenceGap: TimeInterval = 0.03

    public init() {}

    public static var isInteractive: Bool { isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0 }

    public var size: (columns: Int, rows: Int) {
        var ws = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0, ws.ws_row > 0 {
            return (Int(ws.ws_col), Int(ws.ws_row))
        }
        return (100, 30)
    }

    /// Enters raw mode and the alternate screen. Always pair with `restore()`. If the process is killed or
    /// crashes meanwhile, or exits without calling `restore()`, the terminal is put back anyway.
    public func enter() {
        guard !isRaw else { return }
        let saved = TerminalRestore.saved
        tcgetattr(STDIN_FILENO, saved)
        var raw = saved.pointee
        raw.c_iflag &= ~tcflag_t(BRKINT | ICRNL | INPCK | ISTRIP | IXON)
        raw.c_oflag &= ~tcflag_t(OPOST)
        raw.c_cflag |= tcflag_t(CS8)
        raw.c_lflag &= ~tcflag_t(ECHO | ICANON | IEXTEN | ISIG)
        withUnsafeMutableBytes(of: &raw.c_cc) { bytes in
            bytes[Int(VMIN)] = 0
            bytes[Int(VTIME)] = 1
        }
        TerminalRestore.arm()
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
        isRaw = true
        write("\u{1B}[?1049h\u{1B}[?25l\u{1B}[H\u{1B}[2J")
    }

    public func restore() {
        guard isRaw else { return }
        TerminalRestore.disarm()
        isRaw = false
    }

    public func write(_ text: String) {
        var data = Array(text.utf8)
        var offset = 0
        while offset < data.count {
            let n = data.withUnsafeMutableBytes { Darwin.write(STDOUT_FILENO, $0.baseAddress! + offset, $0.count - offset) }
            if n <= 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                return
            }
            offset += n
        }
    }

    /// Waits up to `timeout` seconds for input and returns every key in it. A key sequence cut off at the end
    /// of a read gets one short wait for the rest, so a split arrow key isn't read as Escape.
    public func readKeys(timeout: TimeInterval) -> [TerminalKey] {
        guard let bytes = readAvailable(timeout: timeout) else { return [] }
        var parsed = KeyParser.parse(bytes)
        var keys = parsed.keys
        while !parsed.rest.isEmpty {
            guard let more = readAvailable(timeout: Terminal.sequenceGap) else { return keys + KeyParser.flush(parsed.rest) }
            parsed = KeyParser.parse(parsed.rest + more)
            keys += parsed.keys
        }
        return keys
    }

    private func readAvailable(timeout: TimeInterval) -> [UInt8]? {
        var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        guard poll(&pfd, 1, Int32(timeout * 1000)) > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: 256)
        let count = read(STDIN_FILENO, &buffer, buffer.count)
        guard count > 0 else { return nil }
        return Array(buffer[0..<count])
    }

    /// While on, SIGTERM, SIGHUP and SIGINT don't end the process: the terminal is put back at once and the
    /// signal is kept in `heldSignal`, so work that must not stop halfway (a cleanup) can finish first.
    public func holdTerminationSignals(_ hold: Bool) {
        TerminalRestore.holding.pointee = hold ? 1 : 0
    }

    /// A termination signal that arrived while signals were held. The terminal has already been put back,
    /// so nothing should be drawn any more.
    public var heldSignal: Int32? {
        let signal = TerminalRestore.held.pointee
        return signal == 0 ? nil : Int32(signal)
    }

}

/// Puts the terminal back from signal handlers and `atexit`.
///
/// Signal handlers may only call async-signal-safe functions, so everything they need is prepared up front
/// in memory that is never reallocated: the saved terminal settings and the bytes that leave the alternate
/// screen. The handlers then only call `write(2)`, `tcsetattr(3)`, `signal(3)` and `raise(3)`, and set `sig_atomic_t` flags.
private enum TerminalRestore {
    nonisolated(unsafe) static let saved: UnsafeMutablePointer<termios> = {
        let pointer = UnsafeMutablePointer<termios>.allocate(capacity: 1)
        pointer.initialize(to: termios())
        return pointer
    }()
    nonisolated(unsafe) static let bytes: UnsafeBufferPointer<UInt8> = {
        let sequence = Array("\u{1B}[0m\u{1B}[?25h\u{1B}[?1049l".utf8)
        let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: sequence.count)
        _ = buffer.initialize(from: sequence)
        return UnsafeBufferPointer(buffer)
    }()
    nonisolated(unsafe) static let armed = flag()
    /// 1 while termination signals are held.
    nonisolated(unsafe) static let holding = flag()
    /// The termination signal that arrived while held, or 0.
    nonisolated(unsafe) static let held = flag()
    static let terminationSignals = [SIGTERM, SIGHUP, SIGINT]
    static let fatalSignals = terminationSignals + [SIGQUIT, SIGABRT, SIGTRAP, SIGILL, SIGSEGV, SIGBUS]
    // Read and written only by `arm()`, which runs on the UI thread, never from a signal handler.
    nonisolated(unsafe) private static var registeredAtExit = false

    private static func flag() -> UnsafeMutablePointer<sig_atomic_t> {
        let pointer = UnsafeMutablePointer<sig_atomic_t>.allocate(capacity: 1)
        pointer.initialize(to: 0)
        return pointer
    }

    static func arm() {
        // Touch every static before a handler can run, so handlers never trigger their lazy initialisation.
        _ = (saved, bytes, armed, holding, held)
        armed.pointee = 1
        for signal in fatalSignals { Darwin.signal(signal, restoreAndReraise) }
        for signal in terminationSignals { Darwin.signal(signal, restoreAndHoldOrReraise) }
        if !registeredAtExit {
            registeredAtExit = true
            atexit(restoreAtExit)
        }
    }

    static func disarm() {
        run()
        for signal in fatalSignals { Darwin.signal(signal, SIG_DFL) }
    }

    /// Async-signal-safe.
    static func run() {
        guard armed.pointee != 0 else { return }
        armed.pointee = 0
        _ = Darwin.write(STDOUT_FILENO, bytes.baseAddress, bytes.count)
        tcsetattr(STDIN_FILENO, TCSAFLUSH, saved)
    }
}

private func restoreAndReraise(_ signal: Int32) {
    TerminalRestore.run()
    Darwin.signal(signal, SIG_DFL)
    raise(signal)
}

private func restoreAndHoldOrReraise(_ signal: Int32) {
    guard TerminalRestore.holding.pointee != 0 else {
        restoreAndReraise(signal)
        return
    }
    TerminalRestore.run()
    TerminalRestore.held.pointee = sig_atomic_t(signal)
}

private func restoreAtExit() {
    TerminalRestore.run()
}
