# Measurement methodology

Every number on screen, in the CSV and in this document uses four words:

* **Direct** – reported by a system interface as-is.
* **Calculated** – arithmetic on direct values.
* **Estimated** – a model or attribution, not a physical measurement.
* **Unavailable** – this Mac / macOS does not expose it (or the source is not producing credible data). No number is shown.

The in-app **Sources** tab lists the same catalogue (`MeasurementCatalog` in `PowerFlowKit`), computed from what the
Mac is producing right now.

| Quantity | Kind | Source | Notes / limits |
| --- | --- | --- | --- |
| Adapter input | Direct (SMC) / Calculated (registry fallback) | SMC `PDTR`; fallback `AppleSmartBattery.PowerTelemetryData.SystemPowerIn` | Power delivered to the Mac by the adapter as seen by the power hardware. **Not AC wall power.** Updates about once a second via SMC, about once a minute via the registry |
| Battery power | Calculated | SMC `B0AV` (mV) x `B0AC` (mA); fallback registry Voltage x Amperage | Positive into the battery. Sign convention from the hardware |
| System load | Calculated | adapter input - battery power | Derived on purpose so the three flows balance. On battery it equals the battery discharge. Includes display, SSD, radios |
| System total (PSTR) | Direct | SMC `PSTR` | Undocumented key, independently sampled; cross-check only. Observed to differ from the derived load by several watts moment to moment |
| GPU power | Direct | IOReport "Energy Model" `GPU Energy`, delta / elapsed time | Only that block. Unprivileged. Undocumented API |
| CPU / Neural Engine / memory power | Unavailable on this M1 Pro under macOS 27 | IOReport `CPU Energy`, `ANE0`, `DRAM0` | The counters return the same cumulative value on every read, so nothing is reported rather than 0 W. They are shown the moment a counter is seen to advance |
| Total SoC power | Unavailable | – | Needs `powermetrics` (root). Not used. Summing partial blocks would understate it |
| Wall (AC outlet) power | Unavailable | – | Not exposed by macOS. A plug-in meter measures it. Adapter conversion loss is unknown |
| Per-app power | Estimated | `proc_pid_rusage` `ri_energy_nj`, delta / elapsed time; helpers folded into parent app | CPU energy attribution only; roughly half of real power per the original README's measurements; skips root-owned processes; excludes GPU, display, WindowServer |
| Not attributed (residual) | Calculated | system load - sum of attributed app watts | A remainder, not a measurement |
| Runtime if unplugged | Estimated | remaining Wh / 60 s average load | Nominal 3.8 V per cell for Wh. Assumes constant load |
| Battery %, state, health, cycles, temperature | Direct | IOPowerSources, `AppleSmartBattery` | Health is capacity, not power |
| Session / range statistics | Calculated | recorded samples | Average, peak, minimum, trapezoid energy over **measured** time only; gaps longer than 15 s are skipped, never filled |

## Display versus record

* Live figures are lightly smoothed (35 % weight on each new reading; snapped when the change exceeds 25 W).
* History stores **raw** readings, one every 5 seconds (the latest reading at that moment, not an average).
* If the sensor-glitch guard had to substitute a previous reading, that tick is stored with the three flow values **missing**.
* The first GPU sample after launch or wake is missing because IOReport needs two samples to form a delta.

## CSV

`history.csv` (same format for export): UTF-8, header row, LF line endings, no quoting. Empty cell = not measured (never 0).

| Column | Meaning |
| --- | --- |
| `timestamp_utc` | `yyyy-MM-dd HH:mm:ss`, UTC (Excel / Power BI parse this as a datetime) |
| `unix_seconds` | same instant, seconds since 1970 |
| `battery_percent` | 0-100 |
| `external_connected`, `charging` | 1 / 0 |
| `adapter_input_w_direct` | watts |
| `battery_w_calculated` | watts, positive = charging |
| `system_load_w_calculated` | watts |
| `system_total_w_smc_pstr` | watts |
| `gpu_w_ioreport` | watts |
| `power_source` | `smc` or `registry` |

Excel: Data > From Text/CSV. Power BI: Get Data > Text/CSV; set `timestamp_utc` to Date/Time.
