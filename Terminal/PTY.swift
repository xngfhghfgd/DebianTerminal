//
//  PTY.swift
//  DebianTerminal
//
//  Thin wrapper around openpty() that yields the master/slave file descriptors
//  used by VMProcess. Kept separate so the low-level PTY handling is isolated
//  from the process plumbing.
//

import Foundation
import Darwin

struct PTY {
    let master: Int32
    let slave: Int32

    enum PTYError: Error {
        case openFailed(Int32)
    }

    /// Open a new pseudo-terminal pair. The slave is suitable for becoming the
    /// child's controlling terminal / stdio; the master is read/written by us.
    static func open() throws -> PTY {
        var master: Int32 = -1
        var slave: Int32 = -1
        // Default termios, window size 80x24.
        var w = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        let rc = withUnsafeMutablePointer(to: &w) { wp in
            openpty(&master, &slave, nil, nil, wp)
        }
        guard rc == 0 else {
            throw PTYError.openFailed(errno)
        }
        return PTY(master: master, slave: slave)
    }
}
