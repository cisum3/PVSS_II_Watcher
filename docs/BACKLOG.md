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
- Remote bind / auth (explicitly out of the current security model — localhost only)

### Reporting (post-2.4)
- Keyword organize path (parked from V1)
- Driver type-in search (parked — picker is enough for most sites)
- ~~Omit modules with zero hits.~~ **Dropped 2026-09-08.** Reconsidered: a zeroed section is
  worth more than a cleaner page, because "we looked and there was nothing" is itself a
  triage answer. 2.4's behaviour stands.

### Performance (post-2.4)
_Scan cost was never a 2.4 regression — the 2.3 baseline was measured on a much faster
desktop, and the apparent slowdown was the move to a slower laptop. See `PROGRESS-V2.4.md`
4A/4F for the back-to-back A/B on one machine._
- **Inline the four hot helpers into `Process-LogLine`**: `Add-Pattern` (55 % of the
  function), `Ensure-Minute` / `Ensure-MinuteArea` (20 %), `Get-PerfCategory` (15 %),
  `Normalize-Message` (13 %). PowerShell call overhead dominates the scan — removing ~8
  calls per line should cut it by roughly 70 %. Same trick 4A used on the rule loop.
  Mechanical but ugly; the §10.1 byte-identical check makes it verifiable.
- ~~Add `Scope` to rules that only fire for one component.~~ **Done 2026-09-08** — 7 rules
  scoped, 12 of 23 now gated, 44 % fewer rule evaluations. See `PROGRESS-V2.4.md` 4A.
- **Multi-scope (`Scope` as an array).** `trend.seqLess` and `alarm.alertIdUnknown` fire for
  exactly two drivers (`GmsBACnet` + `ApogeeDrv`) and so cannot be gated by a single
  substring. Allowing `Scope = @('GmsBACnet','ApogeeDrv')` is ~4 lines in `Register-RuleSet`,
  but it changes the locked rule shape in PRD §4.1, so it waits for the next version.

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
  comparisons in `Build-Findings` (`Watch-PvssLog.ps1` 1812-1930) plus the 14 rule
  `FindingAt` values. The model already exists at the top of that function: the
  critical-severity finding is a *percentage of parsed lines*, so it is scale-free today.
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
- Fuller multi-line log reassembly (beyond single-header-line parse)
- Rule-engine extensions, if the field asks: cross-line correlation, and per-rule rate
  thresholds in the rule table (the declarative half of the Findings-scaling item above).
  Neither is expressible in the 2.4 rule table.

---

## Known bugs

_Found while testing 2.4 (2026-09-08). None block the release._

**Fixed before the 2.4 zip:** the time-window desync and the `â€¦` encoding bug, plus the
mechanical half of the detections readability pass. See `PROGRESS-V2.4.md` "Pre-ship fixes".

- **Snapshot download locked up on a live server.** Seen once during live-server testing,
  not reproducible locally. Unknown whether it is size, a slow client, tailing during the
  download, or the listener blocking while the snapshot is built. Needs a repro before a
  fix; if it recurs, capture the log size, the window, and whether the host console was
  still printing tail activity.

- **Entire-window caching feels wrong.** Switching away from Entire and back re-reads far
  more than expected — the cache appears not to be written until the window is exited,
  so the expensive path runs when the operator can feel it. Investigate when
  `Save-EntireCache` actually fires and whether the state clone can be made incremental or
  cheaper. Related: batch mode already skips the cache entirely (`PROGRESS-V2.4.md` 4E).

- **Detections UI — mostly closed.** 2.4 shipped the noise fixes, then worst-first ranking
  by rate over each rule's own span, a threshold badge and the span duration
  (`PROGRESS-V2.4.md` "Detections ranking"). Two smaller items were not taken: the raw
  sample line is still the visually dominant element in each rule block, and a bucket
  dimension's meaning ("by subArea") is not self-explanatory to a first-time reader.

- **Detections renders in two places.** `Convert-SnapshotToHtml` and `renderDetections` in
  `app.js` build the same markup independently. The 10.1 check keeps batch and dashboard
  *snapshots* byte-identical, but nothing verifies the live dashboard view against them —
  the two only stay consistent because both get edited together. A drift check, or driving
  the dashboard view from the same payload shape under test, would close it.

---

## Parking lot

_One-liners as they come up in the field:_

-
