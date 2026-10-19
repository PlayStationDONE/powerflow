# PowerFlow security audit

Method: **manual review of all source, scripts and CI config** (about 4,000 lines before changes), plus a
re-review of every changed or added file, plus a few targeted checks (greps, `otool -L`, `codesign`,
`lsof`, file-permission listings). No automated vulnerability scanner or SAST tool was run; none is
installed and none was installed. This is a code review, not a penetration test, and a clean result
does not prove absence of defects.

Nothing from the repository was executed until its scripts had been read. No privileged command, `sudo`,
`powermetrics`, or installer was run. `./build.sh install` was **not** run; the app was only launched from
`build/PowerFlow.app` and quit again.

Summary: **no Critical, High or Medium findings.** Two design limitations (undocumented interfaces) and several
Low/Informational items.

## Checklist results

| Area | Result | Evidence |
| --- | --- | --- |
| sudo / root / helpers / daemons / agents | None | grep for `Process(`, `NSTask`, `posix_spawn`, `system(`, `popen`, `sudo`, `LaunchAgent`, `XPC`: no hits in `Sources/` |
| Kernel/system extensions, entitlements | None; no entitlements file; hardened runtime enabled | `codesign -d --entitlements -` empty; `flags=0x10002(adhoc,runtime)` |
| AppleScript / Accessibility / Full Disk Access / TCC | None requested | no `NSAppleScript`, `AXIsProcessTrusted`; hotkey uses Carbon `RegisterEventHotKey` |
| External process execution | **None** in the app. Only `build.sh` runs `swift`, `codesign`, `python3`, `iconutil`, `pkill`, `cp`, `rm` with fixed strings | source review |
| Network / telemetry / updates | None | no `URLSession`, `Network`, `WebKit`, sockets in source; `otool -L` shows no network/WebKit framework; `lsof -a -p <pid> -i` empty during a 10 s run |
| Credentials / keys | None | review |
| Dependencies | None (no `Package.resolved`, no packages) | `Package.swift` |
| Downloaded binaries / dynamic loading | One `dlopen` added by this work: fixed path `/usr/lib/libIOReport.dylib` (S-02) | `ComponentEnergy.swift` |
| Filesystem writes | Only `~/Library/Application Support/PowerFlow/history.csv` (new), UserDefaults, user-chosen export file, QA `--render*` PNGs to user-supplied CLI paths | review |

## Findings

| ID | Severity | Type | Component | Status |
| --- | --- | --- | --- | --- |
| S-01 | Informational | Design limitation | `SMCReader` uses the undocumented AppleSMC user client | Documented, not removable |
| S-02 | Informational | Design limitation (introduced here) | `ComponentEnergyReader` uses undocumented IOReport | Mitigated |
| S-03 | Low | Confirmed weakness | `build.sh` hid codesign failures | Fixed |
| S-04 | Low | Confirmed weakness | `make-icon.py` recursive delete of a derived path | Fixed (by reading only) |
| S-05 | Low | Residual risk | Ad-hoc signed, not notarised, not sandboxed | Open |
| S-06 | Informational | Privacy | Process names read via `proc_pid_rusage`/`NSWorkspace` | By design, local only |
| S-07 | Informational | Privacy | New local history log | Controls added and tested |
| S-08 | Informational | Persistence | Optional login item | By design |
| S-09 | Informational | Supply chain | CI actions pinned by tag, not SHA | Open |
| S-10 | Informational | Hygiene | QA CLI flags write PNGs to arbitrary caller-supplied paths | Unchanged |
| S-11 | Informational | Hygiene | `build.sh install` deletes and replaces `~/Applications/PowerFlow.app` | Unchanged |
| S-12 | Low | Potential (new code) | History export could overwrite the live log | Fixed and tested |

### S-01 AppleSMC user client (Informational, design limitation)
* File: `Sources/PowerFlowKit/SMCReader.swift`.
* Evidence: `IOServiceOpen` on `AppleSMC`, `IOConnectCallStructMethod(conn, 2, ...)` with `data8` set to `5` (read bytes) or `9` (read key info) only (`readBytes`, `readKeyInfo`).
* Impact: the interface and key names are undocumented and can change; a wrong struct layout could return garbage. It cannot write because no write selector exists in the code.
* Remediation: validate ranges (already done in `PowerReader.readSMC`), fall back to the registry (already done), say so in docs (done). A documented alternative with 1 Hz resolution does not exist.
* Verified: code review; live reads on this M1 Pro are plausible and the derived identity adapter - battery = load held in all 72 recorded rows.

### S-02 IOReport through `dlopen` (Informational, introduced by this work)
* Evidence: `dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW)` then `dlsym` of seven symbols; any missing symbol returns nil.
* Impact: an undocumented API could change or crash on a different OS. The absolute system path avoids search-path hijacking; hardened runtime library validation still applies to anything else.
* Mitigation: the component becomes "Unavailable" rather than showing a number; counters that never advance are never reported (`ComponentEnergyTracker`, tested).
* Verified: loaded and returned GPU watts under the hardened-runtime build on this Mac; failure paths are unit-tested only at the tracker level, not by forcing a missing library.

### S-03 `build.sh` swallowed signing errors (Low, confirmed, fixed)
* Evidence (original): `codesign --force --sign - "$OUT" 2>/dev/null || echo "(ad-hoc signing skipped)"`.
* Impact: an unsigned or broken bundle could be installed without notice.
* Fix: `codesign --force --sign - --options runtime` followed by `codesign --verify --strict`, under `set -e`.
* Verified: ran `./build.sh`; `codesign -dv` shows `adhoc,runtime`.

### S-04 `make-icon.py` derived-path `rm -rf` (Low, confirmed by reading, fixed)
* Evidence (original): `iconset = out.replace(".icns", ".iconset")` then `rm -rf iconset`; with an `out` lacking `.icns` the two are equal.
* Impact: only reachable by passing an unusual path by hand (`build.sh` passes a fixed one). Would delete the output path.
* Fix: exit unless `out` ends in `.icns`; `iconset` derived by suffix replacement.
* Verified: **not executed** (Pillow is not installed here, so the script cannot run); fix confirmed by reading.

### S-05 Ad-hoc signing, no notarisation, no sandbox (Low, open)
The app is not sandboxed because the SMC and process-accounting reads would not be allowed. It holds no entitlements and requests no permission other than an optional notification prompt. Distribution to other people would need a Developer ID signature and notarisation. Open by nature of a local build.

### S-06 Process names and energy (Informational)
`AppEnergySampler`/`RunningApps` read process names, parents and energy counters for the current user's processes. Used for the on-screen list only; **not** written to history (`HistorySample` has no app fields), not logged, not sent anywhere.

### S-07 History log (Informational, controls added)
New: `~/Library/Application Support/PowerFlow/history.csv`; directory `0700`, file `0600` (unit-tested and confirmed on disk), 7-day retention pruned at launch, writes batched every 12 samples, can be turned off, exported to a user-chosen file, and deleted from the dashboard or menu. Contains only timestamps, charge %, plug/charging flags and watt readings.

### S-08 Login item (Informational)
`SMAppService.mainApp.register()` only when the user ticks "Launch at Login". Off by default. No LaunchAgent plist is written by the app.

### S-09 CI (Informational, open)
`.github/workflows/ci.yml` uses `actions/checkout@v4` by tag. No secrets, no deploy. Pinning by SHA would harden it. Not changed (not part of the app).

### S-10 / S-11 QA flags and install script (Informational, unchanged)
`--render`, `--filmstrip`, `--animtest`, `--render-menubar`, `--selftest` write PNGs to paths the caller passes. `./build.sh install` runs `pkill -x PowerFlow` and `rm -rf ~/Applications/PowerFlow.app`, a fixed path under the user's home, only when explicitly invoked.

### S-12 Export could overwrite the history log (Low, found in new code, fixed)
`HistoryStore.export` resolves symlinks and refuses `destinationIsStorageFile`; covered by `exportRefusesToOverwriteTheStorageFile`.

## Privacy statement (justified)
Inspection found no code that opens a network connection, and a runtime check of open sockets over 10 s found none.
That supports "no network activity observed and none in the source"; it is not a proof for every code path of the
system frameworks the app links.

## Unresolved risks
Undocumented SMC/IOReport interfaces (S-01, S-02); unsigned-for-distribution status (S-05); open CI pinning (S-09);
the icon script fix was not executed (S-04).
