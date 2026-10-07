//
//  TerminalInput.swift
//  DebianTerminal
//
//  Maps a semantic key press to the byte sequence the guest's terminal expects.
//  These are the escape sequences emitted for an ANSI-ish serial console on
//  ttyAMA0, so arrow keys / Ctrl / Tab / Enter behave correctly in bash's
//  readline inside the guest.
//

import Foundation

/// A semantic keyboard event, independent of the underlying keyboard hardware.
enum TerminalKey: Equatable, Hashable {
    case enter
    case tab
    case esc
    case backspace
    case delete
    case up, down, left, right
    case home, end
    case pageUp, pageDown
    /// A control chord, e.g. `.ctrl("c")` for Ctrl-C, `.ctrl("d")` for EOF.
    case ctrl(Character)

    /// The raw byte sequence to write to the serial console.
    ///
    /// Control characters use the classic ASCII mapping: Ctrl-A = 0x01 … Ctrl-Z
    /// = 0x1A. Function/editing keys use the ECMA-48 CSI sequences.
    var rawBytes: [UInt8] {
        switch self {
        case .enter:    return [0x0D]                          // \r
        case .tab:      return [0x09]                          // \t
        case .esc:      return [0x1B]                          // \e
        case .backspace: return [0x7F]                         // DEL
        case .delete:   return [0x1B, 0x5B, 0x33, 0x7E]        // \e[3~
        case .up:       return [0x1B, 0x5B, 0x41]              // \e[A
        case .down:     return [0x1B, 0x5B, 0x42]              // \e[B
        case .right:    return [0x1B, 0x5B, 0x43]              // \e[C
        case .left:     return [0x1B, 0x5B, 0x44]              // \e[D
        case .home:     return [0x1B, 0x5B, 0x48]              // \e[H
        case .end:      return [0x1B, 0x5B, 0x46]              // \e[F
        case .pageUp:   return [0x1B, 0x5B, 0x35, 0x7E]        // \e[5~
        case .pageDown: return [0x1B, 0x5B, 0x36, 0x7E]        // \e[6~
        case .ctrl(let c):
            // Map a letter to its control code: Ctrl-A (0x01) .. Ctrl-Z (0x1A).
            let upper = Character(String(c).uppercased())
            let ascii = upper.asciiValue.flatMap { Int($0) }
            if let a = ascii, a >= 0x41 && a <= 0x5A {          // 'A'..'Z'
                return [UInt8(a - 0x40)]
            }
            return [UInt8(c.asciiValue ?? 0)]
        }
    }
}
