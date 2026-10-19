# Feature verification report

Machine: MacBook Pro, Apple M1 Pro, macOS 27.0.1, Swift 6.4 (Command Line Tools, no Xcode), built against the
macOS 26.5 SDK (the 27.0 SDK needs Xcode's SwiftUI macro plugin). Tests: **91 passed, 0 failed** (`swift test`; 64 ported
original tests + 27 new).

Legend: **Impl** implemented · **Tested** automated tests cover the logic · **Target** exercised on this Mac ·
**Gap** what is not verified.

| Feature | Impl | Tested | Target | Notes / Gap |
| --- | --- | --- | --- | --- |
| Live adapter / battery / load (SMC, 1 Hz) | Yes | Decode + flow reconciliation | **Yes** – `--probe`, `--smc`, 72 recorded rows; adapter - battery = load held in every row | Not compared against an external wall meter or `powermetrics` |
| Power-flow (Sankey) diagram | Yes | Layout geometry | Popover self-test drew pixels; offscreen render inspected | Live popover not viewed interactively |
| Runtime if unplugged | Yes | Yes | Value computed only when unplugged data exists; `--` shown otherwise | Accuracy not validated by a real discharge |
| Per-app energy | Yes (labelled estimate) | Aggregation | Rows appear with real apps in popover self-test | Attribution accuracy is the kernel's; ~half of real power per original README |
| Charge markers + notifications | Yes | No (UI) | Not exercised | Needs interactive test |
| Menu bar item + ⌥⌘P hotkey | Yes | No | **Yes** – self-test: item reachable, hotkey registered, popover shown | |
| Right-click menu (new: dashboard, history items) | Yes | No | Not exercised | Needs interactive click |
| Launch at login | Yes | No | Not exercised | |
| Sleep / wake | Yes | No | **No** – no sleep cycle performed | IOReport reset and history flush are new, untested at run time |
| Battery health / cycles / temperature | Yes | Parsing | Read from the live registry (dashboard) | |
| SoC component power: GPU | Yes | Tracker, units | **Yes** – 1.2-1.4 W values recorded while idle with dashboard open | Not cross-checked against `powermetrics` (needs root) |
| SoC component power: CPU / ANE / DRAM | Unavailable here | Tracker gating | Counters observed frozen | Revisit on another macOS release |
| Total SoC power | **Unsupported** | – | – | Needs root `powermetrics` |
| Wall power | **Unsupported** | – | – | Not exposed by macOS |
| History recording (5 s, 7 days, local CSV) | Yes | Store, CSV, prune, perms | **Yes** – file created `0600` in a `0700` folder, rows parse | Long-run (days) retention not observed |
| History charts with honest gaps | Yes | Segmenting, decimation | Window launched without error; **chart not viewed** | Needs a visual check |
| CSV export (Excel / Power BI) | Yes | Export + header tests | Save-panel path not exercised | Open in Excel/Power BI not done |
| Delete history | Yes | Yes | Confirmation dialog not exercised | |
| Dashboard window (Live, History, Apps, Sources) | Yes | – | Launched with `--dashboard`, stayed up, 1.8 % CPU, no log output | **Not visually inspected** (screen access was declined) |
| Liquid Glass styling | Yes (`glassEffect`, 26+) | – | Compiled and ran | **Visual result not inspected**; Reduce Transparency path not exercised |
| Accessibility (labels, Reduce Transparency / Motion) | Partial | – | – | VoiceOver not exercised |
| WidgetKit widget (S/M/L) | **No** | – | – | Blocked: needs Xcode, signing identity, App Group (see AUDIT_REPORT.md §5) |
| App icon | Yes (supplied artwork, `Resources/AppIcon.icns`) | – | In the built bundle; **not viewed in Finder/Dock** | Cropped from a ~500 px preview, so large sizes are soft; supply a 1024 px original to sharpen |
| Offline / no telemetry | Yes | – | No sockets during 10 s `lsof` | |
| Resource use | Yes | – | Idle (panel closed) 0.1 % CPU, 55 MB; dashboard open 1.8 % CPU | Rolling-digit transition removed after it measured ~25 % CPU |
