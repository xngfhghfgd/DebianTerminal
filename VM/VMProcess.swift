//
//  VMProcess.swift
//  DebianTerminal
//
//  Low-level child-process wrapper for QEMU. Uses a pseudo-terminal (PTY): the
//  child's stdin/stdout/stderr are the PTY slave; Swift owns the PTY master.
//  This gives a proper interactive line discipline through QEMU's serial
//  console (PL011 UART over `-serial mon:stdio`).
//

import Foundation
import Darwin

final class VMProcess {

    // MARK: - Public surface
    var onOutput: ((Data) -> Void)?
    var onExit: ((Int32) -> Void)?
    var onError: ((String) -> Void)?

    private(set) var pid: pid_t = -1

    // PTY fds
    private var masterFD: Int32 = -1

    private let readQueue = DispatchQueue(label: "debianterminal.vm.read")
    private var running = false
    private var exitCode: Int32 = 0

    // MARK: - Launch
    /// Spawn `argv[0]` with the rest of `argv`, wiring stdio to a fresh PTY.
    /// `env` may be nil to inherit a trimmed environment.
    func launch(argv: [String], env: [String: String]? = nil) throws {
        guard argv.count > 0 else {
            throw VMError.qemuLaunchFailed("empty argv")
        }

        // Create the pty pair.
        let pty: PTY
        do {
            pty = try PTY.open()
        } catch {
            throw VMError.qemuLaunchFailed("openpty failed (errno=\(errno))")
        }
        var master: Int32 = pty.master
        let slave: Int32 = pty.slave
        masterFD = master

        // Login shell for the child; set the pty slave as controlling terminal.
        var fds: [Int32] = [slave, slave, slave]

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)

        // dup2 slave -> stdin/stdout/stderr
        for (idx, fd) in fds.enumerated() {
            posix_spawn_file_actions_adddup2(&actions, fd, Int32(idx))
        }
        // Close the slave fd in the child once duplicated.
        posix_spawn_file_actions_addclose(&actions, slave)
        // Reclaim descriptors >= 3 in the child. The _np variant (closefrom)
        // is macOS-only; on iOS the duplicated slave is enough for QEMU.
        #if os(macOS)
        posix_spawn_file_actions_add_closefrom_np(&actions, 3)
        #endif

        // Build a C argv.
        var cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cArgs.append(nil)

        // Build a C envp (filtered environment, PATH present).
        var envDict: [String: String] = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            "LANG": "C.UTF-8",
        ]
        if let env { envDict.merge(env) { _, new in new } }
        var cEnv: [UnsafeMutablePointer<CChar>?] = envDict.map { strdup("\($0.key)=\($0.value)") }
        cEnv.append(nil)

        defer {
            posix_spawn_file_actions_destroy(&actions)
            for p in cArgs { if let p { free(p) } }
            for p in cEnv { if let p { free(p) } }
            close(slave)
        }

        var child: pid_t = 0
        let rc = posix_spawn(&child, argv[0], &actions, nil,
                             &cArgs, &cEnv)
        if rc != 0 {
            close(masterFD); masterFD = -1
            throw VMError.qemuLaunchFailed("posix_spawn rc=\(rc) errno=\(errno)")
        }
        pid = child
        running = true

        startReadLoop()
    }

    // MARK: - Reading
    private func startReadLoop() {
        readQueue.async { [weak self] in
            guard let self else { return }
            let bufSize = 4096
            var buf = [UInt8](repeating: 0, count: bufSize)
            while self.running {
                // Non-blocking-ish read: block on master, deliver chunks.
                let n = read(self.masterFD, &buf, bufSize)
                if n > 0 {
                    let data = Data(buf[0..<n])
                    DispatchQueue.main.async {
                        self.onOutput?(data)
                    }
                } else if n == 0 {
                    break // EOF
                } else {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK {
                        usleep(10_000)
                        continue
                    }
                    break
                }
            }
            self.waitForExit()
        }
    }

    // MARK: - Writing
    func write(_ data: Data) {
        guard masterFD >= 0 else { return }
        let n = data.withUnsafeBytes { ptr in
            Darwin.write(masterFD, ptr.baseAddress, data.count)
        }
        if n < 0 {
            let msg = String(cString: strerror(errno))
            DispatchQueue.main.async { self.onError?(msg) }
        }
    }

    /// Send a raw byte string (e.g. terminal escape sequence).
    func writeString(_ s: String) {
        write(Data(s.utf8))
    }

    // MARK: - Exit
    private func waitForExit() {
        var status: Int32 = 0
        let r = waitpid(pid, &status, 0)
        if r >= 0 {
            // WEXITSTATUS() is a function-like C macro and not exposed to Swift
            // on iOS; compute it by hand (exit code is the status high byte).
            if (status & 0x7F) == 0 {
                exitCode = (status >> 8) & 0xFF
            } else {
                // Terminated by a signal: report 128+signal (shell convention).
                exitCode = Int32(128 + Int(status & 0x7F))
            }
        }
        running = false
        if masterFD >= 0 { close(masterFD); masterFD = -1 }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let code = self.exitCode
            if code != 0 {
                self.onExit?(code)
                self.onError?("qemu-system-aarch64 exited with status \(code)")
            } else {
                self.onExit?(0)
            }
        }
    }

    // MARK: - Signal / termination
    /// Send SIGTERM to the guest for a graceful shutdown.
    func signalTerminate() {
        guard pid > 0 else { return }
        kill(pid, SIGTERM)
    }

    /// Force kill (SIGKILL).
    func forceKill() {
        guard pid > 0 else { return }
        kill(pid, SIGKILL)
    }

    func isRunning() -> Bool { running }
}
