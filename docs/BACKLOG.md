# Future backlog — PVSS Log Analyzer

**Shipped baseline:** Watch **2.3** · OfflineAnalyze **1.3** · Author: Cisum (2026-09-07)
**In progress:** **2.4** — declarative rule engine; OfflineAnalyze absorbed as report mode.
Spec: [`PRD-V2.4.md`](PRD-V2.4.md) · Tracker: [`PROGRESS-V2.4.md`](PROGRESS-V2.4.md).
4A-4F done; 4G docs done, `Watch\OfflineAnalyze\` deletion and the field zip still pending.

**Rule:** Keep this file short — ideas as bullets, not specs. Active scope lives in the PRD
and tracker; historical requirements in [`archive/`](archive/).
Anything shipping to the field needs a **version bump** first (`VERSION.txt` + user-facing
`readMe.txt` / `CHANGELOG.txt`). Keep root [`CHANGELOG.txt`](../CHANGELOG.txt)
operator-focused — no docs/backlog links.

---

## Ideas / improvements

_Not scoped into 2.4. Promote to a PRD when one becomes the next version._

### Watch
- WebSocket / SSE vs poll (parked — adaptive poll covers most UX gain)
- Manager instance rollup helpers
- Remote bind / auth (out of current security model — localhost only)
- **Finer chart bar granularity.** Today only minute / hour / day. Prefer
  **1m → 5m → 10m → 15m → 1h → 6h → 12h → 1d**, rolled up from existing minute buckets,
  with thresholds tuned so bar count stays readable on live windows and Entire.

### Reporting
- Keyword organize path (parked from V1)
- Driver type-in search (parked — picker is enough for most sites)

### Performance
- **Inline hot helpers in `Process-LogLine`:** `Add-Pattern`, `Ensure-Minute` /
  `Ensure-MinuteArea`, `Get-PerfCategory`, `Normalize-Message`. PowerShell call overhead
  dominates; same approach as 4A on the rule loop. Verify with the §10.1 byte-identical check.
- **Multi-scope (`Scope` as an array).** `trend.seqLess` and `alarm.alertIdUnknown` fire for
  exactly two drivers and cannot use a single `Scope` string. Changes the locked rule shape
  (PRD §4.1), so wait for the next version.

### Detection / parsing
- **BACnet emits four Apogee-scoped message families and none of them are reported.** The
  `apogeeDrv.*` rules are gated to `WCCOAApogeeDrv` because that is what 2.3 counted and 4A
  froze it. Across the 12-log corpus every out-of-scope hit is `WCCOAGmsBACnet`:
  trend buffer overflow 10,845 · sequence-number-greater 10,846 · AlertID 11,003 ·
  query timeout 5,675. The clearest tell is that the *"less than saved"* variant
  (`trend.seqLess`) is reported for BACnet while *"greater than saved"* is not.
  Fix is new BACnet-scoped rules, not widening the Apogee ones — the Apogee card's counts
  must stay as they are. Same class of gap 4B closed with `trend.dataLoss`.
- **Scale the Findings thresholds to the window.** Every threshold that can raise a Findings
  headline is an absolute count, but the same code serves a 60-minute dashboard window and a
  four-month batch report — so the numbers can only be right at one scale. The corpus shows
  how wide the gap is: `driver.offline` fires 4,506 times in **7 seconds** on C2P, while
  `state.unexpected` fires 3,179 times across **four months** on the same log. Both clear
  their thresholds the same way, and only one is an incident. Affects ~19 hardcoded
  comparisons in `Build-Findings` plus the 14 rule `FindingAt` values. The model already
  exists at the top of that function: the critical-severity finding is a *percentage of
  parsed lines*, so it is scale-free today.
  **Scope note:** this only affects which Findings fire. It cannot reorder Detections — a
  window-derived factor is the same divisor for every rule, so it cancels out of the
  ranking (`PROGRESS-V2.4.md` "Detections ranking"). The two are independent.
  Three things to settle first:
  - Thresholds need triage, not blanket scaling. Rate-like counts (BACnet chatter, CNS
    volume, Apogee failures, every `FindingAt`) should scale; **presence** checks must not —
    one project restart or one pmon blocking event matters in any window; and
    **cardinality** checks (devices ended Failed, flapper count) scale with system size
    rather than time.
  - Normalize against elapsed time or against parsed lines? Per-hour reads naturally but
    an idle overnight gap deflates it; per-1,000-lines is steadier but less intuitive.
  - Needs clamping at both ends, or an entire-file report spanning months drops every
    finding and a 60-second live tail raises all of them.
  Changes report text, so it needs the §10.1 check re-run and a CHANGELOG note.
- **Relate severe / high-volume traffic to project startup.** Severity (especially SEVERE)
  often skyrockets around a restart; we already detect project up / shutdown / stopped and
  build cycles. Next step is not more detection — it is characterizing the traffic relative
  to those markers: does the burst come **before** `up`, **after**, or **span** the
  startup window (e.g. shutdown→stopped→up, or up through driver-ready)? Use the corpus to
  see what a "normal startup plume" looks like (duration, severity mix, which managers /
  modules dominate) so later Findings or UI can tag or down-weight startup noise vs a real
  incident. Ties into Findings window-scaling above.
- Fuller multi-line log reassembly (beyond single-header-line parse)
- Rule-engine extensions if the field asks: cross-line correlation; per-rule rate thresholds
  in the rule table (declarative half of Findings scaling)

---

## Known bugs

_None of these block the 2.4 release._

- **Host console catch-up % feels inaccurate.** Successive `Catch-up ... N%` lines can
  stall or jump. Console is throttled (`+10%` or every 3s in `Update-LoadProgress`); UI
  reads `%` more often. Confirm whether the % is wrong or only the throttle looks odd.
- **Snapshot download locked up once on a live server.** Not reproduced locally. If it
  recurs: log size, window, and whether the host was still printing tail activity.
- **Entire-window caching feels wrong.** Leaving Entire and returning re-reads more than
  expected — cache may not be written until the window is exited. Check when
  `Save-EntireCache` fires. Batch mode already skips the cache (4E).
- **Detections UI leftovers:** sample line still dominates each rule block; bucket labels
  like "by subArea" are not self-explanatory.
- **Detections renders in two places.** `Convert-SnapshotToHtml` and `renderDetections`
  in `app.js` duplicate markup. Snapshots stay byte-identical via §10.1; the live view
  does not. Drift check or one shared payload shape would close it.

---

## Parking lot

_One-liners as they come up in the field:_

-
