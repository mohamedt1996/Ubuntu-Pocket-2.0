# Debian Pocket — server-tools-1 / 1.1.0 (UTM 4.7.5)

This is a revised SOURCE build kit, not a compiled IPA. It retains Debian 13,
Docker and UTM 4.7.5's prebuilt ARM64 QEMU framework.


## New in server-tools-1

- General editable TCP and UDP forwarding. Add, edit, disable or delete mappings before boot; changes made during a session apply after clean shutdown and a full app relaunch. The active-session list remains separate from saved settings. Duplicate protocol/host ports and invalid port numbers are rejected. All binds use iPhone loopback, not the Wi-Fi interface.
- Any Docker server can be mapped; this does not automatically publish every container port. For `docker run -p 8080:80 ...`, set Debian port 8080 and choose a free iPhone port. Open the matching localhost URL for HTTP services. UDP and non-web TCP services need their own clients. SSH's 2222 mapping can be edited or removed; there is no special case for Stremio.
- Tools → Open server provides saved links and an in-app browser. A link is not a health check and a Docker process can be running without serving HTTP. The browser has no certificate-validation bypass.
- Permanent public DNS (1.1.1.1 and 8.8.8.8), including migration on existing disks. Run Tools → Install / update guest tools ONCE at an idle root prompt after installing the new IPA. No disk reset. Resolver backup: /etc/resolv.conf.before-pocket. DNS choice is editable in Debian's /etc/resolv.conf; running the updater again reapplies these defaults.
- Safe shutdown uses a dedicated QMP socket and the guest power button. It never injects shutdown text into your active terminal program. The app waits for a guest-originated shutdown, tells QEMU to exit, waits for cleanup, then shows Safe to close. If the guest ignores the power button, it reports the delay instead of killing the VM; run `poweroff` at an idle root prompt. Full app relaunch is still required for another boot.
- Persistent terminal view across sheets, copy/paste confirmation, Ctrl+C/Esc/Tab/arrows, 9–26pt font controls, keyboard toggle, bounded recent-output search/export, and shell-size synchronization. Selection/copy is provided by SwiftTerm. Transcript search is recent raw console output with CSI escapes removed, not a full terminal-screen search.
- Fresh disks include tmux. On an older disk run `apt install tmux`, then Tools → Start / resume tmux session. New/next window buttons send Ctrl+B C/N and require tmux to be active. Sessions persist while the VM is alive, not through shutdown.
- Experimental terminal PiP renders the terminal as a read-only video at 1fps using AVSampleBufferDisplayLayer. Enable the inline preview, wait for availability, then tap Start PiP. Use the system PiP return control to restore the terminal. No keyboard input in PiP. No silent audio or fake location updates. UIBackgroundModes audio is declared for PiP, but LiveContainer's own host capabilities and iOS determine availability. No promise of indefinite background execution; no claim of on-device PiP verification.
- Keep-screen-awake is optional. Normal background grace time remains bounded; minimizing/closing PiP or locking the device may suspend the VM.

## Validation for this revision

Local checks: Python and shell syntax; DNS migration with a real temporary symlink and repeat update; existing native C JIT contract and debugger polling tests; shell Docker probe tests; simulated console network/APT/clock success and failure cases; Swift source grammar checks (not Xcode typechecking).

GitHub gates: compile/run forwarding-model tests on macOS, build the actual iOS app, boot the real ARM64 image for Docker/DNS/HTTP/HTTPS/APT/clock, then a second snapshot boot to test two host-to-guest TCP/UDP echo services and QMP graceful shutdown. Both boots have explicit deadlines and saved logs. The second boot uses Python echo services to isolate forwarding; it does not claim a Docker container image was pulled or started. No IPA is published unless every gate passes.

The Xcode build, actual ARM64 gates, and PiP/LiveContainer behavior have not been executed in this editing environment. Keep the prior working IPA until the new build and device checks pass.

## Build and install

1. Copy all files, including `.github/workflows/build.yml`, into your existing
   repository. The root `build.yml` is an identical convenience copy: if you
   upload files individually, place it at `.github/workflows/build.yml`.
2. Run **Build Debian Pocket IPA**. The workflow must pass the image boot/Docker
   gate and the Xcode build before it packages a release.
3. Install the new `DebianPocket.ipa` into LiveContainer, replacing the existing
   app while preserving its data. Fully close the existing session first.
4. Confirm settings and the terminal say **server-tools-1 / UTM 4.7.5**. If they do not,
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

## bootfix-7 — quiet console, network checks and limited background time

The iPhone has now booted bootfix-5. The screenshot shows APT waiting to connect,
not a successful remote download. No on-device internet success is claimed.

- Normal iOS boot keeps systemd service status lines but removes ignore_loglevel
  and uses quiet/loglevel=3 so informational kernel audit messages stay off the
  terminal. System logs remain available through journalctl/dmesg.
- New images install pocket-status (actual local service/address/route states)
  and pocket-net (DNS plus a bounded IPv4 HTTPS mirror request).
- APT uses IPv4 and finite connection timeouts; QEMU's guest IPv6 is disabled.
  This addresses a possible IPv6 path problem, not a proven cause of the stall.
- CI now requires the guest mirror HTTPS check as well as Docker readiness.
  This tests GitHub's network path, not your iPhone's VPN/Wi-Fi/cellular path.
- The app requests UIKit's finite background grace period on leaving foreground
  and ends it on return or expiry. It cannot guarantee always-on background
  execution, survive force-quit, or override LiveContainer/iOS suspension.

### Existing disk: no reset needed

Install the new IPA, launch Debian, stop any running apt command with Ctrl+C,
and wait for the root prompt. Tap **Guest tools → Install**. This runs the bundled
idempotent guest-update.sh inside your existing VM; it does not reinstall Debian
or erase data. Then use:

    pocket-status
    pocket-net
    apt update

You are already root, so sudo is unnecessary. If pocket-net fails, copy its
output; it distinguishes interface/route configuration, name lookup and HTTPS
without guessing that the internet is available.

You can quiet the current session and test APT before rebuilding:

    dmesg -n 3
    apt-get -o Acquire::ForceIPv4=true -o Acquire::http::Timeout=15 -o Acquire::https::Timeout=15 update

Validation: shell/workflow syntax and simulated serial/network result cases.
This iOS source update has not been compiled or tested on-device here.

## bootfix-7 — host clock and mandatory guest APT gate

QEMU now explicitly uses a UTC host-backed RTC. The launcher passes the iPhone's timezone to Debian; pocket-clock applies it at boot and corrects clock drift every minute, including after suspension. Existing disks need Guest tools → Install at an idle root prompt once. That action also sets the current iPhone time immediately. No disk reset is needed. Older running sessions need a full app restart to use the new RTC option.

GitHub's boot gate now requires guest DNS, HTTP, HTTPS, a clock within 30 seconds of the runner, and a real apt-get update with APT::Update::Error-Mode=any. Failed repository downloads fail the build even if cached indexes exist. HTTP/HTTPS probes are bounded, APT is limited to 180 seconds, and the overall boot gate remains 600 seconds. The snapshot disk keeps CI downloads out of the shipped image.

These checks run in Linux QEMU, not the iOS UTM framework. They do not prove that an iPhone's current network, VPN, DNS or embedded QEMU backend works. Capture pocket-net output on the phone if APT still hangs. Timezone changes are picked up on next VM launch or Guest tools installation. Clock drift correction can only run while iOS allows the process to execute.
