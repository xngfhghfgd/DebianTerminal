//
//  VMManager.swift
//  DebianTerminal
//
//  Top-level lifecycle orchestrator. Owns the VMProcess and the terminal
//  session, enforces the state machine (stopped/starting/running/stopping/
//  crashed), implements graceful + forced shutdown, and surfaces errors.
//

import Foundation
import Combine

@MainActor
final class VMManager: ObservableObject {

    @Published private(set) var state: VMState = .stopped
    @Published var lastError: String?

    /// Config may be mutated from Settings then persisted.
    @Published var config: VMConfig = VMConfig.load()

    /// The terminal session that carries the serial console I/O to the UI.
    let terminalSession = TerminalSession()

    private let qemuManager = QEMUManager()
    private var vmProcess: VMProcess?
    private var shutdownWorkItem: DispatchWorkItem?

    // MARK: - Boot
    func start() {
        guard state == .stopped || state == .crashed else { return }

        // Seed bundled kernel/initrd/qemu into Documents/Debian on first run.
        VMConfig.seedRuntimeFilesFromBundle()

        // Re-validate everything up front: QEMU, JIT, kernel, disk.
        if let err = qemuManager.validate(config: config) {
            lastError = err.errorDescription
            state = .crashed
            return
        }

        state = .starting
        lastError = nil
        terminalSession.reset()

        do {
            let proc = try qemuManager.launch(config: config)
            vmProcess = proc

            proc.onOutput = { [weak self] data in
                self?.terminalSession.feed(data: data)
            }
            proc.onExit = { [weak self] code in
                self?.handleExit(code: code)
            }
            proc.onError = { [weak self] msg in
                self?.lastError = msg
            }

            // Wire terminal writes back into the QEMU PTY.
            terminalSession.onSend = { [weak proc] data in
                proc?.write(data)
            }

            state = .running
            terminalSession.emitPromptPlaceholder()
        } catch {
            lastError = (error as? VMError)?.errorDescription ?? error.localizedDescription
            state = .crashed
        }
    }

    // MARK: - Graceful stop
    func stop() {
        guard state == .running else { return }
        state = .stopping

        // Ask systemd inside the guest to power off.
        terminalSession.writeLine("shutdown -h now")
        terminalSession.writeLineAfterDelay("sudo shutdown -h now", seconds: 0.8)

        let work = DispatchWorkItem { [weak self] in
            self?.forceStop()
        }
        shutdownWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(config.shutdownTimeoutSeconds),
                                      execute: work)
    }

    func forceStop() {
        shutdownWorkItem?.cancel()
        shutdownWorkItem = nil
        if let proc = vmProcess {
            proc.forceKill()
        }
        transitionToStopped()
    }

    func restart() {
        guard state == .running || state == .crashed else { return }
        if state == .running {
            stop()
        }
        // Give the previous instance a moment to fully exit.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.start()
        }
    }

    // MARK: - Exit handling
    private func handleExit(code: Int32) {
        vmProcess = nil
        if state == .stopping {
            transitionToStopped()
        } else if code != 0 {
            state = .crashed
            lastError = "QEMU terminated unexpectedly (exit \(code))."
        } else {
            transitionToStopped()
        }
    }

    private func transitionToStopped() {
        shutdownWorkItem?.cancel()
        shutdownWorkItem = nil
        state = .stopped
        vmProcess = nil
        terminalSession.detach()
    }

    // MARK: - Status
    func isRunning() -> Bool { state == .running }
}
