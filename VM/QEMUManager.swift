//
//  QEMUManager.swift
//  DebianTerminal
//
//  Locates the bundled QEMU binary, verifies the guest components and JIT,
//  and translates a VMConfig into a launched VMProcess.
//

import Foundation
import Darwin

final class QEMUManager {

    /// Locate the QEMU sever binary: bundle resource, else Debian dir, else nil.
    func locateQEMUBinary() -> URL? {
        let bundled = VMConfig.bundledQEMUURL()
        if FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        let deb = VMConfig.debianDirectory().appendingPathComponent("qemu-system-aarch64")
        if FileManager.default.isExecutableFile(atPath: deb.path) {
            return deb
        }
        return nil
    }

    /// Validate the whole toolchain. Returns an error message describing the
    /// first missing component, or nil if ready.
    func validate(config: VMConfig) -> VMError? {
        guard let qemu = locateQEMUBinary() else {
            return .qemuNotFound
        }
        if !JITDetector.isJITAvailable() {
            return .jitUnavailable
        }
        let kernel = config.kernelURL()
        if !FileManager.default.fileExists(atPath: kernel.path) {
            return .kernelMissing(kernel.path)
        }
        let disk = config.diskImageURL()
        if !FileManager.default.fileExists(atPath: disk.path) {
            return .diskImageMissing(disk.path)
        }
        return nil
    }

    /// Spawn QEMU for the given config. Returns the live VMProcess.
    func launch(config: VMConfig) throws -> VMProcess {
        if let err = validate(config: config) {
            throw err
        }
        let binary = locateQEMUBinary()!
        let args = [binary.path] + config.qemuArguments()

        let proc = VMProcess()
        try proc.launch(argv: args, env: ["QEMU_AUDIO_DRV": "none"])
        return proc
    }
}

/// Quick JIT availability probe. On iOS this checks whether executable memory
/// can be allocated (the entitlement grants MAP_JIT). It never crashes.
final class JITDetector {
    static func isJITAvailable() -> Bool {
        #if targetEnvironment(simulator)
        return true
        #elseif os(iOS)
        // Try to allocate an executable page. If the JIT entitlement is
        // missing this fails with EPERM/ENOTSUP. On iOS the hardened runtime
        // requires MAP_JIT (see Docs/JIT.md); this probe is a best-effort gate
        // and the real proof is QEMU actually starting.
        let pageSize = Int(getpagesize())
        let prot = PROT_READ | PROT_WRITE | PROT_EXEC
        let flags = Int32(MAP_ANON | MAP_PRIVATE | MAP_JIT)
        let ptr = mmap(nil, pageSize, prot, flags, -1, 0)
        if ptr == MAP_FAILED {
            return false
        }
        munmap(ptr, pageSize)
        return true
        #else
        return true
        #endif
    }
}
