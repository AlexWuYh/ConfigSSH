import Darwin
import Foundation

package enum BoundedProcessRunner {
    package static func run(_ process: Process, timeout: TimeInterval) throws -> Int32 {
        guard timeout > 0 else { throw ConfigEditError.invalid("子进程超时时间必须大于零") }
        let completed = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completed.signal() }
        try process.run()
        if completed.wait(timeout: .now() + timeout) == .timedOut {
            if process.isRunning { process.terminate() }
            if completed.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
                // Not yet reaped, so the PID still belongs to our child.
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                _ = completed.wait(timeout: .now() + 1)
            }
            throw ConfigEditError.io("外部工具执行超时，已停止子进程")
        }
        return process.terminationStatus
    }
}
