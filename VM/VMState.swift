//
//  VMState.swift
//  DebianTerminal
//
//  Lifecycle state of the guest.
//

import Foundation

enum VMState: String, Codable, CaseIterable, Sendable {
    case stopped
    case starting
    case running
    case stopping
    case crashed

    var displayName: String {
        switch self {
        case .stopped:  return "Stopped"
        case .starting: return "Starting"
        case .running:  return "Running"
        case .stopping: return "Stopping"
        case .crashed:  return "Crashed"
        }
    }

    var isActive: Bool {
        switch self {
        case .starting, .running, .stopping: return true
        case .stopped, .crashed:             return false
        }
    }
}

/// A structured error that surfaces a human-readable cause instead of
/// "Unknown Error".
enum VMError: LocalizedError {
    case qemuNotFound
    case jitUnavailable
    case kernelMissing(String)
    case diskImageMissing(String)
    case jitCheck(message: String)
    case qemuLaunchFailed(String)
    case qemuCrashed(Int32)
    case diskCorrupt(String)

    var errorDescription: String? {
        switch self {
        case .qemuNotFound:
            return "QEMU executable not found"
        case .jitUnavailable:
            return "JIT is required to run the Debian virtual machine."
        case .kernelMissing(let p):
            return "Linux kernel image not found: \(p)"
        case .diskImageMissing(let p):
            return "Debian disk image not found: \(p)"
        case .jitCheck(let m):
            return "JIT check failed: \(m)"
        case .qemuLaunchFailed(let m):
            return "Failed to launch QEMU: \(m)"
        case .qemuCrashed(let code):
            return "QEMU crashed with exit code \(code)"
        case .diskCorrupt(let p):
            return "Debian disk image is corrupt: \(p)"
        }
    }
}
