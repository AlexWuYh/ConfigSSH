import Darwin
import Foundation

/// Runs a program in its own process group so a timeout or a user cancel stops the whole tree.
///
/// The deploy-key wizard starts `ssh-copy-id` → `ssh` → `configssh-askpass`; killing only the
/// first process would leave ssh running and a password dialog on screen. Arguments are passed as
/// an array (no shell) and the environment is given explicitly, so nothing set here leaks into
/// ConfigSSH itself or into any terminal it launches.
package final class GroupProcess: @unchecked Sendable {
    package struct Result: Sendable {
        package let status: Int32
        package let stdout: String
        package let stderr: String
        package let wasCancelled: Bool
        package let timedOut: Bool
    }

    private let lock = NSLock()
    private var pid: pid_t = 0
    private var cancelled = false
    private var finished = false

    package init() {}

    /// Stops the process group: SIGTERM first, SIGKILL if it is still alive a second later.
    package func cancel() {
        lock.lock()
        cancelled = true
        let target = finished ? 0 : pid
        lock.unlock()
        guard target > 0 else { return }
        terminateGroup(target)
    }

    package func run(executable: URL, arguments: [String], environment: [String: String],
                     timeout: TimeInterval, outputLimit: Int = 256 * 1024) throws -> Result {
        guard timeout > 0 else { throw ConfigEditError.invalid("子进程超时时间必须大于零") }
        lock.lock()
        let alreadyCancelled = cancelled
        pid = 0
        finished = false
        lock.unlock()
        if alreadyCancelled {
            return Result(status: 130, stdout: "", stderr: "", wasCancelled: true, timedOut: false)
        }
        var outPipe: [Int32] = [0, 0]
        var errPipe: [Int32] = [0, 0]
        guard pipe(&outPipe) == 0 else { throw ConfigEditError.io("无法创建管道：系统错误 \(errno)") }
        guard pipe(&errPipe) == 0 else {
            close(outPipe[0]); close(outPipe[1])
            throw ConfigEditError.io("无法创建管道：系统错误 \(errno)")
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        for descriptor in [outPipe[0], outPipe[1], errPipe[0], errPipe[1]] {
            posix_spawn_file_actions_addclose(&actions, descriptor)
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setpgroup(&attributes, 0)
        var defaultSignals = sigset_t()
        sigfillset(&defaultSignals)
        posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF |
                                                    POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var child: pid_t = 0
        let spawnStatus = posix_spawn(&child, executable.path, &actions, &attributes, argv, envp)
        close(outPipe[1]); close(errPipe[1])
        guard spawnStatus == 0 else {
            close(outPipe[0]); close(errPipe[0])
            throw ConfigEditError.io("无法启动 \(executable.lastPathComponent)：系统错误 \(spawnStatus)")
        }
        lock.lock()
        pid = child
        let cancelledEarly = cancelled
        lock.unlock()
        if cancelledEarly { terminateGroup(child) }

        let readers = DispatchGroup()
        let collected = OutputBox()
        for (descriptor, isError) in [(outPipe[0], false), (errPipe[0], true)] {
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                let data = Self.drain(descriptor, limit: outputLimit)
                close(descriptor)
                collected.set(data, isError: isError)
                readers.leave()
            }
        }

        let deadline = Date().addingTimeInterval(timeout)
        var status: Int32 = 0
        var timedOut = false
        while true {
            let result = waitpid(child, &status, WNOHANG)
            if result == child { break }
            if result < 0 && errno != EINTR { break }
            if Date() >= deadline, !timedOut {
                timedOut = true
                terminateGroup(child)
            }
            usleep(50_000)
        }
        lock.lock()
        finished = true
        let wasCancelled = cancelled
        lock.unlock()
        // The group leader is gone; make sure no member (ssh, askpass) outlives it.
        _ = kill(-child, SIGKILL)
        _ = readers.wait(timeout: .now() + 2)

        let exitCode: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        return Result(status: exitCode,
                      stdout: String(decoding: collected.stdout, as: UTF8.self),
                      stderr: String(decoding: collected.stderr, as: UTF8.self),
                      wasCancelled: wasCancelled, timedOut: timedOut)
    }

    private func terminateGroup(_ leader: pid_t) {
        _ = kill(-leader, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let stillRunning = !self.finished
            self.lock.unlock()
            if stillRunning { _ = kill(-leader, SIGKILL) }
        }
    }

    private static func drain(_ descriptor: Int32, limit: Int) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count > 0 {
                if data.count < limit { data.append(contentsOf: buffer[0..<min(count, limit - data.count)]) }
            } else if count == 0 || errno != EINTR {
                break
            }
        }
        return data
    }
}

private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    func set(_ data: Data, isError: Bool) {
        lock.lock(); defer { lock.unlock() }
        if isError { err = data } else { out = data }
    }
    var stdout: Data { lock.lock(); defer { lock.unlock() }; return out }
    var stderr: Data { lock.lock(); defer { lock.unlock() }; return err }
}
