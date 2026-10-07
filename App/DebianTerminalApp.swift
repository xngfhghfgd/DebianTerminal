//
//  DebianTerminalApp.swift
//  DebianTerminal
//
//  App entry point.
//

import SwiftUI

@main
struct DebianTerminalApp: App {
    @StateObject private var vm = VMManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(vm)
                .preferredColorScheme(.dark)
        }
    }
}
