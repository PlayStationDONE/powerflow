# PowerFlow audit report

Scope: the repository as downloaded (menu-bar app, Swift 6 toolchain in Swift 5 language mode, SwiftPM,
no Xcode project, no third-party dependencies, no Git history). Target: Apple Silicon MacBook Pro (M1 Pro),
macOS 27.0.1, Command Line Tools only (no Xcode installed).

The audit was done by reading every source file, `build.sh`, `scripts/make-icon.py` and the CI file
**before** running anything, then building, running the tests and running the read-only probes.
This file records the state found. "Status after this work" columns say what changed.

## 1. Project structure

| Item | Finding |
| --- | --- |
| Targets | `PowerFlowKit` (library, no UI), `PowerFlow` (executable, AppKit + SwiftUI), `PowerFlowKitTests` |
| Entry point | `@main enum PowerFlowMain` in `Sources/PowerFlow/App.swift`; many `--flag` QA modes, otherwise `NSApplication` with `.accessory` policy (menu bar only) |
| UI | `NSStatusItem` + transient `NSPopover` hosting SwiftUI. Layout reproduced from a reference screenshot (`Spec.swift`) |
| Measurement | SMC user client (`PDTR`, `B0AC`, `B0AV`), IOPowerSources, `AppleSmartBattery` registry, `proc_pid_rusage` |
| Background processes | None. Two main-thread `Timer`s (1 s sensors, 3 s per-app) |
| Privileged operations | None found (no root, helper, daemon, agent, entitlement, AppleScript, accessibility, FDA) |
| Persistence | `UserDefaults` (marker %, menu bar style); optional login item via `SMAppService.mainApp` (user toggled, off by default) |
| Dependencies | None |
| Build | `build.sh` (swift build, hand-written Info.plist, ad-hoc codesign, optional install to `~/Applications`) |
| Tests | 5 XCTest files; README says 28 tests, the files contain 64 |
| Signing / entitlements | Ad-hoc, no entitlements file, not sandboxed (original script hid signing errors) |
| Widget | None in the original |

## 2. Advertised features and their status

Classes: A verified, B implemented not adequately verified, C partial, D missing, E unsupported here, F unsafe/replace.

| # | Original claim (README) | Class before | What the code actually does | Status after this work |
| --- | --- | --- | --- | --- |
| 1 | Live power flow: adapter in, battery in/out, system load, ~1 s | B | SMC `PDTR`, `B0AC`x`B0AV` at 1 Hz; load is **derived** (adapter - battery) | Works on this M1 Pro (probe + 72 recorded rows). Now labelled Direct/Calculated everywhere |
| 2 | Sankey whose ribbons are the wattages | A (geometry tested) | `SankeyLayout` is pure and tested | Unchanged; also shown in the dashboard |
| 3 | Runtime if unplugged | B | remaining Wh / 60 s average load, 3.8 V/cell nominal | Kept; labelled **Estimated** |
| 4 | Draw by app (per-app watts) | F (label) | `ri_energy_nj` / interval = CPU-energy attribution, ~half of real power, no root-owned processes | Kept (it is the only unprivileged source) but relabelled **estimate**, residual relabelled "Not attributed (residual)", off the main thread |
| 5 | Charge markers (target / floor) | B | UI markers + notification on crossing; do not control charging | Unchanged; README already says so |
| 6 | Menu bar + Option-Command-P hotkey | B | Carbon `RegisterEventHotKey`, no Accessibility permission | Verified by the app's own `--selftest` on this Mac (hotkey registered, popover drew pixels) |
| 7 | Battery health / cycles / temperature / adapter info | B | `AppleSmartBattery`, shown in right-click menu | Also in dashboard; health explicitly separated from power |
| 8 | Launch at login | B | `SMAppService.mainApp`; user-initiated | Unchanged |
| 9 | Sleep/wake handling | B | Reconnects SMC, drops averages | Extended: IOReport baseline reset, history flush on sleep. Not exercised by an actual sleep cycle |
| 10 | "Reads only, no network" | B | Source inspected: no networking APIs or libraries | Confirmed by source grep and `otool -L` (see SECURITY_AUDIT.md) |

Not advertised but requested for this work:

| Requested | Status |
| --- | --- |
| Total SoC / CPU / GPU / ANE power | **Partial.** GPU works unprivileged (IOReport "GPU Energy"). `CPU Energy`, `ANE0`, `DRAM0` counters return an unchanging value on this Mac/macOS 27, so they are reported **Unavailable**. Total SoC is not shown (class E without root `powermetrics`) |
| Wall power | **Unavailable (E).** macOS exposes no AC-side power. `PDTR` is the DC-side input |
| Historical data + charts | **Implemented.** Local CSV log, 5 s samples, 7-day retention, Swift Charts, gaps left blank |
| CSV export / delete data | **Implemented** (dashboard buttons and right-click menu) |
| Dashboard window | **Implemented** (Live, History, Apps, Sources tabs) |
| Liquid Glass | **Implemented** for dashboard cards with `glassEffect` on macOS 26+, material fallback, opaque under Reduce Transparency. The popover keeps its fixed dark reference look. *Not visually inspected by me* (see Limitations) |
| WidgetKit widget | **Blocked (documented).** See section 5 |
| Per-component sums to total | Deliberately **not** done |

## 3. Known bugs and weaknesses found in the original

1. **Build fails on macOS 27 SDK with Command Line Tools only**: `external macro implementation type 'SwiftUIMacros.StateMacro' could not be found`. The plugin ships with Xcode only. Worked around in `build.sh` by retrying with the newest installed 26.x SDK (`POWERFLOW_SDK` overrides). `swift test` needs `--sdk` on this machine for the same reason.
2. **XCTest is not installed** with Command Line Tools, so none of the 64 original tests could run. Ported to Swift Testing through a thin shim (`Tests/PowerFlowKitTests/XCTestShim.swift`); test bodies unchanged. All pass.
3. README claims 28 tests (there are 64) and documents `PPBR`/`PSTR` as the sensors read; the code reads `PDTR`, `B0AC`, `B0AV`. Corrected.
4. `build.sh` silenced `codesign` failures (`2>/dev/null || echo skipped`). Now fails loudly and verifies the signature; adds hardened runtime.
5. `scripts/make-icon.py` deleted `out.replace(".icns", ".iconset")` recursively; with an output path lacking `.icns` that path equals the output. Now rejects such paths.
6. Per-app enumeration of every process ran on the main thread every 3 s. Moved to a utility queue.
7. SampleGuard silently substitutes the previous reading on a sensor dropout; harmless for display but would have been logged as a measurement. History now records those ticks as missing.
8. If `AppleSmartBattery` is unreachable for one tick the panel flips to "No battery". Not changed (low).
9. The UI did not say when it was on the ~1-minute registry fallback. Dashboard now shows the source and freshness.
10. No icon was generated when Pillow is absent (it is absent here). Resolved: the supplied artwork is now committed as `Resources/AppIcon.icns` and `build.sh` uses it.

## 4. Hardware / OS compatibility

* `PDTR`, `B0AC`, `B0AV`, `PSTR` exist and read plausibly on this M1 Pro. Key names are undocumented and may differ on other models/OS releases; the reader returns nil rather than guess and falls back to the registry.
* IOReport is undocumented; only GPU energy is live here (section 2).
* Observation on this Mac: `PSTR` differs from the derived load by about 1-6 W moment to moment, as the original README says of the two sensors.
* Intel Macs fall back to registry values (~1/min). Not tested.

## 5. Widget blocker

WidgetKit needs an app-extension (`.appex`) that is built and embedded by Xcode, signed with a real team identity, and an App Group entitlement to share data. This machine has Command Line Tools only and no Apple developer identity; a widget that shares data through an App Group in practice needs a real signing identity and provisioning (not verifiable on this machine), and Swift Package Manager has no supported way to produce a widget extension. A fake widget (floating window) was explicitly ruled out. **No widget was shipped.** What would be needed: install Xcode, create a Widget Extension target sharing `PowerFlowKit`, add an App Group, and have the app write the latest validated `HistorySample` to the shared container (the model is already in the Kit). Timelines should be requested at most every few minutes.

## 6. Recommended changes (done unless noted)

* Provenance model (`MeasurementKind`) and catalogue shown in the UI: done.
* Unprivileged component power: GPU done; CPU/ANE/DRAM pending an OS release where the counters move, or `powermetrics` (root; deliberately not used).
* Widget: pending Xcode.
* Move `PowerMonitor` logic into the Kit so sampling lifecycle can be unit-tested: not done.
* Pin GitHub Actions by commit SHA: not done (low).
