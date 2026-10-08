//
//  TerminalSession.swift
//  DebianTerminal
//
//  Receives raw serial output from QEMU, strips the ISO-2022 / ANSI control
//  sequences that would render as garbage in SwiftUI Text, and accumulates a
//  scrollback transcript. Also emits typed lines + semantic keys back to QEMU.
//

import Foundation
import Combine

/// All state mutation happens on the main thread (VMManager is @MainActor and
/// VMProcess dispatches serial output onto main); the type is intentionally NOT
/// actor-isolated so it can be used as an @ObservedObject in SwiftUI views on
/// iOS 15 without cross-actor friction.
final class TerminalSession: ObservableObject {

    // MARK: - Published state
    /// The rendered scrollback (ANSI stripped).
    @Published private(set) var transcript: String = ""
    /// Bumped whenever the transcript changes so the view can autoscroll.
    @Published private(set) var flushVersion: Int = 0

    /// Text size for the terminal text.
    @Published var fontSize: CGFloat = 13

    // MARK: - Callbacks
    /// Called with the raw bytes to write back to the VM's PTY.
    var onSend: ((Data) -> Void)?

    // MARK: - Private
    private var rawBuffer: String = ""

    // MARK: - Feed output
    /// Feed a chunk of raw serial output from the VM.
    func feed(data: Data) {
        guard let s = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return
        }
        rawBuffer += s
        // Strip ANSI ESC/CSI sequences; keep the printable text.
        let rendered = Self.stripANSI(from: rawBuffer)
        if rendered != transcript {
            transcript = rendered
            flushVersion += 1
        }
        // Don't let the transcript grow unbounded.
        if transcript.count > 200_000 {
            transcript = String(transcript.suffix(200_000))
            rawBuffer = String(rawBuffer.suffix(4096))
        }
    }

    // MARK: - Write out
    /// Write a line terminated by CR (serial line discipline uses \r).
    func writeLine(_ line: String) {
        let bytes = Data((line + "\r").utf8)
        onSend?(bytes)
    }

    /// Write a line after a short delay (used by shutdown to send a root-less
    /// fallback in case the first didn't take).
    func writeLineAfterDelay(_ line: String, seconds: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.writeLine(line)
        }
    }

    /// Send a semantic terminal key.
    func sendKey(_ key: TerminalKey) {
        onSend?(Data(key.rawBytes))
    }

    /// Reset the session (on a fresh boot).
    func reset() {
        transcript = ""
        rawBuffer = ""
        flushVersion += 1
    }

    /// Detach after the VM exits.
    func detach() {
        onSend = nil
    }

    /// Drop a placeholder prompt so the UI isn't empty before the guest boots.
    func emitPromptPlaceholder() {
        if transcript.isEmpty {
            transcript = "Booting Debian 12…\n"
            flushVersion += 1
        }
    }

    // MARK: - ANSI stripping
    /// Remove CSI (ESC [ ... final), single-char ESC sequences, and known
    /// control chars (except \n/\r) that SwiftUI Text can't render.
    static func stripANSI(from s: String) -> String {
        var out = String()
        out.reserveCapacity(s.count)
        let scalars = Array(s.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let sc = scalars[i]
            if sc.value == 0x1B { // ESC
                // ESC [ or ESC ] -> consume to the final byte.
                i += 1
                if i < scalars.count, scalars[i].value == 0x5B {         // '['
                    i += 1
                    while i < scalars.count {
                        let b = scalars[i]
                        if (0x40...0x7E).contains(b.value) { break }
                        i += 1
                    }
                } else if i < scalars.count, scalars[i].value == 0x5D {  // ']' (OSC)
                    i += 1
                    while i < scalars.count, scalars[i].value != 0x07, scalars[i].value != 0x1B {
                        i += 1
                    }
                }
                i += 1
            } else if sc.value < 0x20 && sc.value != 0x0A && sc.value != 0x0D {
                // Skip other raw control bytes (bell, etc.) but keep LF/CR.
                i += 1
            } else {
                out.unicodeScalars.append(sc)
                i += 1
            }
        }
        return out
    }
}
