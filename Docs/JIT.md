# JIT on iOS — why DebianTerminal needs it, and how to get it

DebianTerminal runs a real, full-system emulation of an AArch64 machine on the
iPhone/iPad. That emulation is done by **QEMU's TCG** (Tiny Code Generator),
which translates each guest ARM64 instruction to a host instruction at runtime
and **executes the translated code from writable+executable memory**. On Apple
platforms this is what the term "JIT" means, and it is gated by the system.

This document explains the mechanism, the entitlements, the runtime probe in the
app, and exactly what a user must do to make it work on a real device.

---

## 1. Why JIT is mandatory here

There is no hardware virtualisation on iOS. Apple exposes no `HVF` (Hypervisor
Framework) to third-party apps, and there is no HAXM/KVM. The only portable path
to run a *different* CPU architecture (guest AArch64) on the device is to emulate
it. A full-system emulator like QEMU must generate native code on the fly:

```
guest ARM64 code ──(TCG translate)──▶ host ARM64 code ──(execute)──▶ CPU
```

That translated code has to live in memory with **`PROT_EXEC`**. On iOS, mapping
a page with `PROT_READ|PROT_WRITE|PROT_EXEC` is denied **unless the app is signed
with the entitlement `com.apple.security.cs.allow-unsigned-executable-memory`**
(and, for the hardened-runtime path, `com.apple.security.cs.allow-jit`).

Without JIT QEMU cannot run at all. There is no `-march=native` / interpreter
fallback for full-system emulation that would be remotely usable.

---

## 2. The entitlements

Attached to the app via `App/DebianTerminal.entitlements`:

| Key | Purpose |
|-----|---------|
| `com.apple.security.cs.allow-unsigned-executable-memory` | Permits allocating pages with `PROT_EXEC` that are unsigned (needed by TCG's code gen buffers). **The critical one.** |
| `com.apple.security.cs.allow-jit` | The modern, hardened-runtime JIT entitlement; sets up the `pthread_jit_write_protect_np` machinery so you can write then execute the region. |
| `com.apple.security.get-task-allow` | Required for the on-device debugging / metal-device attach that a sideloaded (Developer Mode) app uses. Also needed to run a spawned subprocess in many signed contexts. |

These entitlements are **only honored for apps signed with a development
certificate** (a personal team / ad-hoc signing) and **only on a device with
Developer Mode enabled**. An App Store build will *not* be granted
`allow-unsigned-executable-memory`, so a store build cannot JIT.

---

## 3. The runtime probe

`VM/QEMUManager.swift` contains a small, safe self-test used before launch:

```swift
final class JITDetector {
    static func isJITAvailable() -> Bool {
        #if targetEnvironment(simulator)
        return true
        #elseif os(iOS)
        let pageSize = Int(getpagesize())
        let prot = PROT_READ | PROT_WRITE | PROT_EXEC
        let flags = Int32(MAP_ANON | MAP_PRIVATE | MAP_JIT)
        let ptr = mmap(nil, pageSize, prot, flags, -1, 0)
        if ptr == MAP_FAILED { return false }
        munmap(ptr, pageSize)
        return true
        #else
        return true
        #endif
    }
}
```

It tries to `<mmap>` a single RWX anonymous page. If the entitlement is missing
(or Developer Mode is off, or the process is sandboxed as non-JIT), the kernel
returns `EPERM`/`ENOTSUP`, `mmap` fails, and the probe returns `false`. The
`#if targetEnvironment(simulator)` branch returns `true` because the simulator
host is macOS and allows it freely.

`QEMUManager.validate(config:)` calls this probe and reports
`VMError.jitUnavailable` ("JIT is required to run the Debian virtual machine.")
before even attempting to spawn QEMU, so the user gets a clear message rather
than a cryptic crash.

---

## 4. How to make JIT actually work on a device

1. **Enable Developer Mode.** `Settings → Privacy & Security → Developer Mode`
   → on. This is the iOS 16+/17+ switch that allows a sideloaded, dev-signed app
   to use privileged memory and spawn processes. It reboots the device once to
   take effect.
2. **Sign with a development certificate, not a distribution one.** In Xcode use
   *Signing* with your **Personal Team** and *Automatic* signing (or manual
   development provisioning). The entitlements above are copied into the app's
   signature. A Distribution (App Store / Ad Hoc for store) profile will drop
   `allow-unsigned-executable-memory`.
3. **Use a side-loading channel you trust for the profile.** SideStore / AltStore
   (sideloaded via a computer with your Apple ID) re-signs the app with your dev
   certificate and installs it. Because the binary is built for arm64 and JIT is
   allowed, QEMU can then allocate executable pages.
4. **Do not run under a sandbox that strips the entitlement.** A normal
   installed app is sandboxed, but QEMU is a *child process* it spawns; the
   entitlement is inherited. This is why `get-task-allow` is also present.

If `JITDetector` returns `false` on your device, the most likely causes are:
Develop Mode off, the app re-signed without the entitlements (e.g. by a store
channel or by removing `allow-unsigned-executable-memory`), or the OS refusing
to grant JIT to an app whose entitlement signature it doesn't trust.

---

## 5. MAP_JIT and the expert path

On Apple Silicon and A12+ devices, the preferred (and on later iOS versions the
only fully-supported) way is to allocate JIT pages with the **`MAP_JIT`** flag
and to toggle writability with **`pthread_jit_write_protect_np`**:

```c
#include <sys/mman.h>
#include <pthread.h>

void *code = mmap(NULL, size, PROT_READ | PROT_WRITE,
                  MAP_ANON | MAP_PRIVATE | MAP_JIT, -1, 0);
pthread_jit_write_protect_np(0);   // allow writes
/* ... write translated code ... */
pthread_jit_write_protect_np(1);   // make it executable (write-protect)
```

QEMU's TCG on Darwin already uses the appropriate `MAP_JIT`/`mprotect` sequence
for its code buffers. The build (`build-qemu.sh`) configures QEMU with the Apple
hardened-runtime aware `CONFIG_TCG` and the Darwin stubs, so the JIT buffer
path is coherent. The `JITDetector` probe is deliberately the simplest possible
check because a full `MAP_JIT` + write-protect round-trip is only meaningful
once the entitlements are granted.

---

## 6. Caveats you should know

- **Do not expect this to run on a jailbroken-less App Store build.** The
  platform simply won't grant the entitlement. This is expected and by design.
- **Performance.** QEMU TCG full-system emulation on a phone is usable but
  slow (an order of magnitude or more slower than native). A `+2` vCPU / 2 GB
  guest is a reasonable starting point. See `README.md` for tuning.
- **Developer Mode must stay on** for the life of the app session; toggling it
  off mid-run can revoke the entitlement.
- The entitlement file is wired into the project via `project.yml`
  (`entitlements`). If you generate the project with XcodeGen, keep those keys.
