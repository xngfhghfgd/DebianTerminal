//
//  VMConfig.swift
//  DebianTerminal
//
//  Central configuration for the Debian guest. All QEMU parameters are owned
//  here; nothing is hard-coded in the manager layer.
//

import Foundation

/// Which QEMU machine (virt) we emulate.
enum VMMachine: String, Codable, CaseIterable {
    case virt = "virt"
}

/// A single map of user configurable knobs.
struct VMConfig: Codable, Equatable {
    // -- CPU ---------------------------------------------------------------
    /// Number of vCPUs. Allowed: 1, 2, 4.
    var cpuCount: Int = 2

    // -- Memory ------------------------------------------------------------
    /// RAM in MB. Allowed: 1024, 2048, 4096.
    var memoryMB: Int = 2048

    // -- Machine -----------------------------------------------------------
    var machine: VMMachine = .virt
    /// QEMU CPU model. Prefer "max".
    var cpuModel: String = "max"

    // -- Paths (inside the app sandbox) -------------------------------------
    /// Persistent Debian ext4 disk image.
    var diskImageName: String = "debian12.img"
    /// ARM64 kernel Image.
    var kernelName: String = "Image"
    /// Initial RAM disk.
    var initrdName: String = "initrd.img"

    // -- Boot ---------------------------------------------------------------
    var kernelCommandLine: String = "root=/dev/vda rw console=ttyAMA0"

    // -- Network ------------------------------------------------------------
    var networkEnabled: Bool = true

    // -- Duration -----------------------------------------------------------
    /// Grace period (seconds) before a graceful shutdown is force-killed.
    var shutdownTimeoutSeconds: Int = 10

    // -----------------------------------------------------------------------
    // Derived paths
    // -----------------------------------------------------------------------
    /// The app sandbox Documents/Debian directory. Created on first launch.
    static func debianDirectory() -> URL {
        let base = FileManager.default.urls(for: .documentDirectory,
                                            in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Debian", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir,
                                                 withIntermediateDirectories: true)
        return dir
    }

    func diskImageURL() -> URL { Self.debianDirectory().appendingPathComponent(diskImageName) }
    func kernelURL()     -> URL { Self.debianDirectory().appendingPathComponent(kernelName) }
    func initrdURL()     -> URL { Self.debianDirectory().appendingPathComponent(initrdName) }

    /// Where the bundled (read-only) QEMU binary lives inside the app bundle.
    /// Because project.yml copies Resources as a folder reference, the binary
    /// is at `Resources/qemu-system-aarch64`; we also accept a flat location.
    static func bundledQEMUURL() -> URL {
        let bundle = Bundle.main
        let name = "qemu-system-aarch64"
        if let url = bundle.url(forResource: name, withExtension: nil) {
            return url
        }
        if let r = bundle.resourceURL {
            let sub = r.appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: sub.path) {
                return sub
            }
            let flat = r.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: flat.path) {
                return flat
            }
        }
        return bundle.bundleURL.appendingPathComponent(name)
    }

    // -----------------------------------------------------------------------
    // QEMU argument construction
    // -----------------------------------------------------------------------
    /// Builds the full argv for qemu-system-aarch64 from this config.
    ///
    /// Result matches (with tuning for the iOS port):
    ///   qemu-system-aarch64 -machine virt -cpu max -smp 2 -m 2048 \
    ///       -kernel Image -initrd initrd.img \
    ///       -drive file=debian12.img,if=virtio,format=raw \
    ///       -append "root=/dev/vda rw console=ttyAMA0" -nographic
    func qemuArguments() -> [String] {
        var args: [String] = []

        args += ["-machine", machine.rawValue]
        args += ["-cpu", cpuModel]
        args += ["-smp", "\(cpuCount)"]
        args += ["-m", "\(memoryMB)"]

        args += ["-kernel", kernelURL().path]
        if FileManager.default.fileExists(atPath: initrdURL().path) {
            args += ["-initrd", initrdURL().path]
        }

        args += ["-drive", "file=\(diskImageURL().path),if=virtio,format=raw"]

        if networkEnabled {
            // VirtIO net, host-side user networking (slirp). HTTP/HTTPS/DNS work
            // through QEMU's built-in user-mode stack; no external proxy needed.
            args += ["-netdev", "user,id=net0,hostfwd=tcp::2222-:22"]
            args += ["-device", "virtio-net-pci,netdev=net0"]
        } else {
            args += ["-device", "virtio-net-pci"]
        }

        args += ["-append", kernelCommandLine]
        args += ["-nographic"]

        // Serial console goes to stdio; we read/write this on the PTY.
        args += ["-serial", "mon:stdio"]

        return args
    }

    // -----------------------------------------------------------------------
    // Persistence
    // -----------------------------------------------------------------------
    static let configFileName = "config.json"

    func writePersistence(storeURL: URL? = nil) throws {
        let url = storeURL ?? Self.debianDirectory().appendingPathComponent(Self.configFileName)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(self)
        try data.write(to: url)
    }

    static func load(storeURL: URL? = nil) -> VMConfig {
        let url = storeURL ?? Self.debianDirectory().appendingPathComponent(Self.configFileName)
        guard let data = try? Data(contentsOf: url),
              let cfg = try? JSONDecoder().decode(VMConfig.self, from: data) else {
            let c = VMConfig()
            try? c.writePersistence(storeURL: url)
            return c
        }
        return cfg
    }
}
