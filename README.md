# Debian Pocket — bootfix-5 (UTM 4.7.5)

This is a revised SOURCE build kit, not a compiled IPA. It retains Debian 13,
Docker and UTM 4.7.5's prebuilt ARM64 QEMU framework.

## Build and install

1. Copy all files, including `.github/workflows/build.yml`, into your existing
   repository. The root `build.yml` is an identical convenience copy: if you
   upload files individually, place it at `.github/workflows/build.yml`.
2. Run **Build Debian Pocket IPA**. The workflow must pass the image boot/Docker
   gate and the Xcode build before it packages a release.
3. Install the new `DebianPocket.ipa` into LiveContainer, replacing the existing
   app while preserving its data. Fully close the existing session first.
4. Confirm settings and the terminal say **bootfix-5 / UTM 4.7.5**. If they do not,
   you are still running the previous IPA.
5. Keep your working StikDebug universal.js setup for LiveContainer. Start with
   **1024 MB**, **1 CPU**, and an **empty Extra QEMU arguments** field. Previously
   saved settings persist; change them manually if needed.

Do not reset the Debian disk to troubleshoot an empty console. This update
preserves the existing `debian-disk.qcow2` and no longer automatically deletes
an older `ubuntu-disk.qcow2` file.

## Changes

- Uses the underlying QEMU 10.0.2 source ABI: `void qemu_init(int, char **)`,
  `int qemu_main_loop(void)`, `void qemu_cleanup(int)`. UTM's older wrapper
  declarations are not used as the ABI authority.
- Resolves QEMU's own entry points using RTLD_LOCAL | RTLD_FIRST.
- Uses a dedicated connected socket pair for serial instead of replacing
  LiveContainer's stdin/stdout. QEMU errors still go to `qemu.log`.
- Reports entry into and return from qemu_init separately. The state becomes
  running only after serial data arrives; this is not proof of a completed login.
- Requires mmap, a remap variant, mprotect and munmap imports to be hooked.
  Hook-page permission failures are checked rather than ignored.
- Captures only the expected anonymous executable code-cache allocation,
  preventing same-sized guest RAM allocations from taking the JIT region.
- Verifies debugger detach before UTM 4.7.5's separate `brk #0x69` path can run.
- Checks alias protection requests and bounds, preserves actual RW guard pages,
  and flushes the data cache in the initial executable-memory self-test.
- Defaults new installs to one CPU and uses single-thread TCG to reduce variables
  during first-boot verification. Extra QEMU arguments are rejected in this build
  to prevent overriding JIT/console setup or accidentally pausing the VM.
- Adds an identifiable revision, CI build number, UTM-version check, and a guest
  boot test that requires an actual root shell and a responding Docker daemon.

## Validation and limits

Executed here: JIT allocation/protection contract tests compiled with a native C
compiler; Python syntax check; YAML parse; syntax checks for the image builder
and every workflow shell block.

Not executed here: Xcode compilation, the full ARM64 Debian boot test, or an
on-device iOS/LiveContainer JIT launch. This workspace has no Apple SDK or working
QEMU installation. The workflow now performs Xcode compilation and the Linux
boot test; those tests do not certify iOS TXM/JIT permissions.

The original screenshot does not reveal the exact stall location. These changes
fix identifiable integration defects and expose that location if it persists;
they are not a claim that an iPhone boot was reproduced or verified.

## If startup still stalls

Keep the app foregrounded and capture its phase and `code buffer used` line.
Export `qemu.log`, `serial.log`, and `cpu-trace.log` from the app's Documents.

- `inside qemu_init`, code buffer NO: initialization has not handed off the
  prepared cache; inspect QEMU errors and JIT hook logs.
- `inside qemu_init`, code buffer yes: cache handoff happened but initialization
  has not completed.
- `QEMU initialized; waiting for Linux serial`: initialization completed, but no
  guest console bytes have arrived yet.
- `Linux serial active`: inspect the actual Linux messages for further failures.

`cpu-trace.log` records guest errors/unimplemented accesses only. An empty file
is normal and does NOT prove the guest CPU is idle. After any startup failure,
fully close and relaunch; QEMU cannot safely be initialized twice in one process.

## Source references used

- https://github.com/utmapp/UTM/blob/v4.7.5/patches/sources
- https://github.com/utmapp/UTM/blob/v4.7.5/patches/qemu-10.0.2-utm.patch
- https://github.com/utmapp/qemu/blob/v10.0.2-utm/system/vl.c
- https://github.com/utmapp/qemu/blob/v10.0.2-utm/system/runstate.c
- https://github.com/utmapp/qemu/blob/v10.0.2-utm/tcg/region.c
- https://github.com/utmapp/qemu/blob/v10.0.2-utm/chardev/char-socket.c

## bootfix-3 — confirmed CI blocker

Run 38114200743 timed out because systemd-firstboot stopped at
"Please configure your system! -- Press any key to proceed --". Linux reached
userspace; this run did not reach the Docker verification step.

The image builder now configures locale/timezone and masks systemd-firstboot.
Both CI and iOS pass systemd.firstboot=off (also applies to an existing disk).
The smoke test streams console output, prints progress every 15 seconds, and
fails immediately if the interactive wizard reappears. The 600-second deadline
and Docker success requirement are retained. This fix has not yet been rerun
on GitHub or verified on the iPhone.

## bootfix-4 — Docker CLI packaging correction

Run 38134388022 reached a root shell around 107 seconds after VM launch.
The image installed docker.io with --no-install-recommends, which omitted the
separate docker-cli package in Debian 13. The old check hid command errors and
waited even after its retry loop finished. docker-cli is now explicitly installed
and its executable/version checked during image creation. The serial test has
bounded Docker calls, explicit missing-CLI/failure markers and service diagnostics.

No fresh full VM run or iPhone launch has been performed for this revision.
Existing persistent disks do not inherit newly installed packages from the
bundled image: once at their root shell, run `apt-get update && apt-get install -y
docker-cli` to update them without resetting the disk.

## bootfix-5 — debugger-status regression

The old guard returned the same "debugger did not detach" error for both a
failed sysctl query and a positive P_TRACED flag. The screenshot cannot distinguish
those cases. This revision treats failed/short queries as unknown (matching UTM's
handling of unavailable status), retains the executable-region self-test, and
polls a positive flag for up to two seconds before declaring detachment incomplete.
It also disables Start until JIT preparation has completed and reports a relevant
failure hint. It does not change StikDebug settings or erase the guest disk.

A genuinely persistent P_TRACED flag still blocks launch, with an explicit message.
This regression fix has logic tests but has not been tested on an iPhone.
