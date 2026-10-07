//
//  ContentView.swift
//  DebianTerminal
//
//  Root screen: a status header (VM state), Start / Stop / Restart controls,
//  a Settings entry point, and the live serial terminal. The VMManager is
//  injected as an environment object from the app entry point.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var vm: VMManager

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                statusHeader
                    .padding(.horizontal)
                    .padding(.top, 8)

                if let err = vm.lastError {
                    Text(err)
                        .font(.footnote)
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.top, 4)
                }

                controls
                    .padding(.horizontal)
                    .padding(.vertical, 8)

                Divider()

                TerminalView(session: vm.terminalSession) { key in
                    vm.terminalSession.sendKey(key)
                }
            }
            .navigationTitle("Debian 12")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink(destination: SettingsView()) {
                        Image(systemName: "gearshape")
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - Status header
    private var statusHeader: some View {
        HStack {
            Circle()
                .fill(color(for: vm.state))
                .frame(width: 10, height: 10)
            Text(vm.state.displayName)
                .font(.subheadline.weight(.semibold))
            Spacer()
            Text("aarch64 · 6.1.0-53-arm64")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Controls
    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                vm.start()
            } label: {
                Label("Start", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(vm.state == .running || vm.state == .starting)

            Button {
                vm.stop()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.bordered)
            .disabled(vm.state != .running)

            Button {
                vm.restart()
            } label: {
                Label("Restart", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(!(vm.state == .running || vm.state == .crashed))

            Button {
                vm.forceStop()
            } label: {
                Label("Force", systemImage: "xmark")
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .disabled(vm.state == .stopped)
        }
        .font(.subheadline)
    }

    private func color(for state: VMState) -> Color {
        switch state {
        case .stopped:  return .gray
        case .starting: return .yellow
        case .running:  return .green
        case .stopping: return .orange
        case .crashed:  return .red
        }
    }
}
