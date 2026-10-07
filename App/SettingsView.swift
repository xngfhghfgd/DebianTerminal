//
//  SettingsView.swift
//  DebianTerminal
//
//  Form to tune the guest and persist the changes. Everything is written back
//  to Documents/Debian/config.json when the view disappears.
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var vm: VMManager

    // Local editable copies; written back on disappear.
    @State private var cpuCount: Int = 2
    @State private var memoryMB: Int = 2048
    @State private var kernelCmdline: String = "root=/dev/vda rw console=ttyAMA0"
    @State private var diskImage: String = "debian12.img"
    @State private var kernelName: String = "Image"
    @State private var initrdName: String = "initrd.img"
    @State private var networkEnabled: Bool = true
    @State private var shutdownTimeout: Double = 10

    private let cpuChoices = [1, 2, 4]
    private let memChoices = [1024, 2048, 4096]

    var body: some View {
        Form {
            Section(header: Text("CPU")) {
                Picker("Cores", selection: $cpuCount) {
                    ForEach(cpuChoices, id: \.self) { Text("\($0)") }
                }
                .pickerStyle(.segmented)
            }

            Section(header: Text("Memory")) {
                Picker("RAM", selection: $memoryMB) {
                    ForEach(memChoices, id: \.self) { Text("\($0) MB") }
                }
                .pickerStyle(.segmented)
            }

            Section(header: Text("Kernel command line")) {
                TextField("e.g. root=/dev/vda rw console=ttyAMA0", text: $kernelCmdline)
                    .font(.system(.footnote, design: .monospaced))
                    .autocorrectionDisabled(true)
                    .textInputAutocapitalization(.never)
            }

            Section(header: Text("Runtime files (in Documents/Debian)")) {
                TextField("Disk image", text: $diskImage)
                    .autocorrectionDisabled(true)
                TextField("Kernel", text: $kernelName)
                    .autocorrectionDisabled(true)
                TextField("Initrd", text: $initrdName)
                    .autocorrectionDisabled(true)
            }

            Section(header: Text("Network")) {
                Toggle("VirtIO network (slirp)", isOn: $networkEnabled)
            }

            Section(header: Text("Shutdown")) {
                Slider(value: $shutdownTimeout, in: 5...60, step: 1) {
                    Text("Grace timeout")
                } minimumValueLabel: {
                    Text("5s")
                } maximumValueLabel: {
                    Text("60s")
                }
                Text("\(Int(shutdownTimeout)) s")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("Settings")
        .onAppear(perform: loadFromConfig)
        .onDisappear(perform: persist)
    }

    private func loadFromConfig() {
        let c = vm.config
        cpuCount = c.cpuCount
        memoryMB = c.memoryMB
        kernelCmdline = c.kernelCommandLine
        diskImage = c.diskImageName
        kernelName = c.kernelName
        initrdName = c.initrdName
        networkEnabled = c.networkEnabled
        shutdownTimeout = Double(c.shutdownTimeoutSeconds)
    }

    private func persist() {
        var c = vm.config
        c.cpuCount = cpuCount
        c.memoryMB = memoryMB
        c.kernelCommandLine = kernelCmdline
        c.diskImageName = diskImage
        c.kernelName = kernelName
        c.initrdName = initrdName
        c.networkEnabled = networkEnabled
        c.shutdownTimeoutSeconds = Int(shutdownTimeout)
        vm.config = c
        try? c.writePersistence()
    }
}
