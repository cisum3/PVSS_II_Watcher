# Watch 0.4.0 → DesigoLogWatcher 0.5.0 inventory (Phase 5A)

**Baseline:** `Watch\Watch-PvssLog.ps1` + `Watch\PvssRules.ps1` + `Watch\ui\` + `Watch\watch-config.txt`  
**Version file:** `Watch\VERSION.txt` (0.4.0 at inventory time)  
**Purpose:** Contract checklist for C# port. Do **not** invent routes, config keys, rule Ids, or header formats.

---

## 1. CLI parameters (`Watch-PvssLog.ps1` lines 13–45)

| Parameter | Type / validation | Default | Notes |
|---|---|---|---|
| `LogPath` | string | `''` | Explicit path; else auto-discover |
| `Port` | int | `8787` | Dashboard PreferredPort override |
| `LastMinutes` | ValidateRange 1–525600 | `60` | Window; config key `DefaultWindowMinutes` is 1–10080 |
| `RefreshSeconds` | ValidateRange 1–60 | `3` | Dashboard pulse cadence |
| `NoBrowser` | switch | off | Inverts `OpenBrowser` when bound |
| `NoPause` | switch | off | Report/exit: skip keypress wait |
| `TopN` | ValidateRange 5–100 | `10` | Pattern / detection table depth |
| `SamplePerPattern` | ValidateRange **0–5** | `1` | **CLI**; config file allows **1–20** — preserve both |
| `SampleMaxChars` | ValidateRange 100–2000 | `500` | Truncate stored samples |
| `Report` | switch | off | Batch mode; ignores Port/NoBrowser/RefreshSeconds |
| `OutPath` | string | `''` | Report output path |
| `Format` | Text\|Html\|Json\|All | `All` | Report; `Both` accepted as alias for All. Snapshot download uses html\|text\|json |
| `Organize` | All\|Severity\|Driver | `All` | Report/snapshot organization |
| `Severities` | string | `''` | Comma list; also accepts 1–5 menu numbers |
| `Areas` | string | `''` | SYS\|IMPL\|CTRL\|PARAM\|OTHER (+ 1–5) |
| `Driver` | string | `''` | Name substring / list position |
| `Entire` | switch | off | Whole-file window |
| `From` / `To` | string | `''` | Absolute bounds; date-only `To` = end of day |
| `LastHours` | ValidateRange 0–8760 | `0` | Relative; with LastMinutes wins over From/To |
| `Interactive` | switch | off | Report prompts (Enter-defaulted) |

**Dashboard-only behaviors (not separate params):** browser open from config, port fallback tries (`MaxPortTries`), live catch-up %, pause/resume, restart + config reload, `POST /api/logPath` Start.

**CLI precedence:** `$PSBoundParameters` snapshot → `$script:CliOverrides`. Bound CLI always wins over file. Self-correction never writes CLI overrides back.

---

## 2. Config (`watch-config.txt`) — 14 keys

Defaults from `Get-WatchConfigDefaults` (lines 75–92):

| Key | Default | Validation |
|---|---|---|
| PreferredPort | 8787 | int 1–65535 |
| MaxPortTries | 40 | int 1–200 |
| RefreshSeconds | 3 | int 1–60 |
| OpenBrowser | true | bool: 1\|true\|yes\|on / 0\|false\|no\|off |
| Browser | default | default\|chrome\|msedge\|edge\|existing .exe path |
| DefaultWindowMinutes | 60 | int 1–10080 |
| DefaultWindowEntire | false | bool |
| DefaultSeverities | FATAL,SEVERE,ERROR,WARNING | FATAL\|SEVERE\|ERROR\|WARNING\|INFO (drop invalid, keep valid) |
| DefaultAreas | SYS,IMPL,CTRL,PARAM,OTHER | SYS\|IMPL\|CTRL\|PARAM\|OTHER |
| TopN | 10 | int 5–100 |
| SamplePerPattern | 1 | int **1–20** (file) vs CLI **0–5** |
| SampleMaxChars | 500 | int 100–2000 |
| BacFlapMin | 3 | int 1–50 |
| LogPath | '' | string; missing file OK (prefill) |

**Parser (`Read-WatchConfig` 144–333):** UTF-8; trim; skip blank/`#`; `IndexOf('=')` split; unknown keys warned+ignored; malformed lines warned+skipped.

**Self-correction (`Set-WatchConfigKeys` 105–132):** rewrite only corrected keys; preserve comments/order; append missing keys; bools as `true`/`false`; arrays comma-joined.

**LogPath write-back:** `Set-WatchConfigLogPath` on dashboard Start / `POST /api/logPath`. Report mode never writes LogPath.

**Runtime reload (`Apply-WatchConfig -Runtime`):** applies RefreshSeconds, TopN, samples, BacFlapMin, window defaults, severities/areas, LogPath prefill. **Skipped at runtime:** PreferredPort, MaxPortTries, OpenBrowser, Browser (need host relaunch).

---

## 3. HTTP API surface (`Handle-Api` ~4452–4683)

Listener: `http://127.0.0.1:{port}/` only. Static files from `Watch\ui\` (path traversal blocked).

### GET `/api/health`

JSON keys: `ok`, `version`, `author`, `logPath`, `prefillPath`, `listeningUrl`, `port`, `preferredPort`, `refreshSeconds`, `defaults` `{ lastMinutes, windowEntire, severities[], areas[], topN }`, `tailRunning`, `paused`, `loading`, `fileLength`, `lastError`, `generation`.

### GET `/api/pulse`

Query: `severities` (comma; default FATAL/SEVERE/ERROR/WARNING on, INFO off), `areas`, `sinceGeneration` (304 if same gen and not loading).  
Body: `Build-PulseObject` (overview pulse + loading progress).

### GET `/api/section`

Query: **`name` required** + same sev/area filters.  
Known `name` values: `patterns`, `managers`, `bacnet`, `cns`, `coho`, `apogee`, `perf`, `detections`.  
UI maps view `more` → section `perf`.

### GET `/api/manager`

Query: **`name`** (manager/component) + severities. Returns count, severities map, patternsBySeverity, lifecycle.

### GET `/api/snapshot`

Requires session `logPath` and not `loading` (400 / 409).  
Query: severities, areas, `format` (html\|text\|json, default html), `organize` (All\|Severity\|Driver), `drivers` (comma).  
Response: file download (`Write-DownloadResponse`), not inline JSON for html/text/json formats.

### POST `/api/logPath` (Start)

Body JSON: `path` (required), optional `window`=`entire`, optional `lastMinutes`.  
Validates path (`Assert-LogPathUsable`), clears Entire cache, sets LogPath + **persists to config**, runs `Invoke-CatchUp`.  
Response: `{ ok, logPath, generation }` or 400.

### POST `/api/control`

Body JSON: `action` + action-specific fields:

| action | Body fields | Behavior |
|---|---|---|
| `pause` | — | Paused=true, bump generation |
| `resume` | — | Paused=false, bump generation |
| `restart` | — | Stop catch-up/tail, close stream, clear cache, Reset-Analysis, clear LogPath, `Apply-WatchConfig -Runtime` |
| `setWindow` | `window`=`entire` or `lastMinutes` | May Save-EntireCache / Try-Begin-EntireFromCache / Invoke-CatchUp |
| `note` | `message` | Console log only (no bump noise in host log filter) |

Response: `{ ok, generation }` or 400. Unknown action → error.

**Grep check:** all `/api/` routes in `Watch-PvssLog.ps1` are listed above (health, pulse, section, manager, snapshot, control, logPath). No other API paths.

---

## 4. Rules table (`PvssRules.ps1`) — 23 Ids

| Id | Group | Scope | Sample / FindingAt | Notes |
|---|---|---|---|---|
| cns.resolveNodes | CNS | — | PatternGroup=Cns | curated |
| cns.reducedFunction | CNS | — | PatternGroup=Cns | curated |
| cns.icns | CNS | — | PatternGroup=Cns | curated |
| cns.tryRenew | CNS | — | PatternGroup=Cns | curated |
| apogeeDrv.trendOverflow | Apogee | ApogeeDrv | SampleSlot=apogeeDrv.trend | BucketBy trend/device |
| apogeeDrv.trendSeq | Apogee | ApogeeDrv | SampleSlot=apogeeDrv.trend | |
| apogeeDrv.alertId | Apogee | ApogeeDrv | Sample | |
| apogeeDrv.queryTimeout | Apogee | ApogeeDrv | Sample | |
| apogeeDrv.getDataFail | Apogee | ApogeeDrv | Sample | BucketBy device |
| bacnetDrv.trendOverflow | BACnetDrv | GmsBACnet | ShipGate FindingAt=100 | “trend log object” wording |
| bacnetDrv.trendSeq | BACnetDrv | GmsBACnet | ShipGate | companion to overflow |
| bacnetDrv.alertId | BACnetDrv | GmsBACnet | ShipGate | |
| bacnetDrv.queryTimeout | BACnetDrv | GmsBACnet | ShipGate | |
| bacnetDrv.getDataFail | BACnetDrv | GmsBACnet | ShipGate | |
| state.unexpected | Platform | — | FindingAt=500 | BucketBy subsystem/method |
| trend.dataLoss | Trending | GmsBACnet | FindingAt=100 | |
| trend.seqLess | Trending | Ship: GmsBACnet+ApogeeDrv | FindingAt=100 | DevGate unscoped (0.4) |
| driver.errorCode | Driver | — | FindingAt=250 | |
| driver.offline | Driver | CoHo | FindingAt=250 | |
| driver.readFile | Driver | CoHo | FindingAt=250 | |
| alarm.alertIdUnknown | Alarms | — | FindingAt=250 | |
| alarm.getSummaryFail | Alarms | GmsBACnet | FindingAt=100 | |
| device.cptFailed | Devices | GmsBACnet | FindingAt=100 | |
| device.aesDecrypt | Devices | GmsBACnet | FindingAt=100 | |
| afw.traceRepetition | Framework | — | FindingAt=500 | Measure Sum/Max |
| afw.covBurst | Framework | — | FindingAt=250 | Measure Sum/Max |
| afw.serverSideException | Framework | CComMgr | FindingAt=100 | |
| afw.retainedInvocations | Framework | — | FindingAt=500 | |

**Engine knobs:** `CuratedGroups` = BACnet, CNS, CoHo, Apogee; `RuleBucketCap` = 2000; ranking per PRD 6.2 in `Build-DetectionsObject`.

**0.5.0 §2.1 exceptions (shipping = ShipGate):**
- Multi-scope: `RuleDefinition.Scopes` list; `trend.seqLess` → `GmsBACnet` + `ApogeeDrv` (DevGate keeps unscoped 0.4 behavior).
- BACnetDrv families (Scope=`GmsBACnet`, Group=`BACnetDrv`, not widening Apogee): `bacnetDrv.trendOverflow` (BACnet “trend log object” wording), `bacnetDrv.trendSeq`, `bacnetDrv.alertId`, `bacnetDrv.queryTimeout`, `bacnetDrv.getDataFail`.
- Interactive manager ranges `1-3,10` (Cli.ParseManagerRange).
- Toggle: `new RuleEngine(RuleGateMode.DevGate|ShipGate)`; default ShipGate.

---

## 5. Hand-written analysis (outside rule table)

Must port for parity. Primary home: `Process-LogLine` (977–1267), `Build-Findings` (1812–1930), helpers.

| Concern | PS location / regexes | Target C# |
|---|---|---|
| Header parse | `$LineRe` L738 | LogParser / AnalysisState |
| Severity WARN→WARNING | Process-LogLine | AnalysisState |
| Area normalize | `Normalize-AreaKey` | AnalysisState |
| Pattern accumulators | `Add-Pattern`, `Normalize-Message`, `Ensure-Minute*` | AnalysisState |
| Perf categories | `Get-PerfCategory` | AnalysisState |
| BACnet Failed/OK flips + object-list | `ReBacFailed/Ok/ObjList`; BacLastStatus/Flip; BacFlapMin | AnalysisState |
| BACnetCollectTrend / BACnetTimeSync | `ReBacCmdDetail`, fallback cmd regexes | AnalysisState |
| CNS pattern sidecar | after rule hits with PatternGroup=Cns | AnalysisState + RuleEngine |
| CoHo stuck/drop | `ReCohoStuck`, DiscoveryLoc/Cycle | AnalysisState |
| Apogee orch trio | `ReApogeeComp/Update/Rep/Ppcl` | AnalysisState |
| ApogeeDrv line count | comp contains ApogeeDrv | AnalysisState |
| Project/manager lifecycle | ReProject*, RePmonMgrRestart, ReMgr*, ReDriverReady, ReBlocking* | AnalysisState |
| Findings heuristics | `Build-Findings` thresholds + rule FindingAt loop | SnapshotBuilder |
| Entire cache | Save/Try-Begin/Clear-EntireCache | **out of 0.5.0** (not shipping) |

**INFO patterns:** only BACnet status INFO lines (`ReInfoBacStatus`) enter PatternsBySev INFO — not all INFO.

---

## 6. Log discovery & I/O

**`Resolve-LogPath` (1365–1391)** search order:

1. Explicit `-LogPath` → `Assert-LogPathUsable`
2. Exact `PVSS_II.log` then `PVSS_II.log.bak` in: Watch root, parent of Watch, current directory (unique)
3. Newest `PVSS_II*.log` / `PVSS_II*.log.bak` in those dirs
4. Else throw with searched dirs hint

**Open semantics:** `FileMode.Open`, `FileAccess.Read`, `FileShare.ReadWrite`; StreamReader UTF-8, detect BOM, buffer 1 MiB, leaveOpen.

---

## 7. UI static assets

```
Watch\ui\
  index.html
  app.js
  app.css
  vendor\chart.umd.min.js
```

Publish must place/copy `ui\` beside `DesigoLogWatcher.exe` under `Watch\`. Do not rewrite UI contracts.

---

## 8. PS function → C# file map

| PowerShell | C# home |
|---|---|
| Get/Read/Set-WatchConfig*, Apply-WatchConfig, ConvertTo-ConfigBool | `Config.cs` |
| param block, Interactive prompts, window precedence | `Cli.cs` + `Program.cs` |
| Open/Close-LogStream, Resolve-LogPath, Find-WindowStartPosition, catch-up/tail, Read-TailBytes | `LogParser.cs` |
| New-EmptyState, Process-LogLine (non-rule), Normalize-*, Add-Pattern, lifecycle | `AnalysisState.cs` |
| PvssRules + Add-RuleHit, Register-RuleSet, Build-DetectionsObject | `RuleEngine.cs` + `Rules\` |
| Build-SnapshotObject, Build-Findings, Build-Pulse/Section/Manager | `SnapshotBuilder.cs` |
| Convert-SnapshotToHtml/Text, report writers | `ReportWriter.cs` |
| Handle-Api, Handle-Request, Start-Listener, static ui | `HttpServer.cs` |

---

## 9. Grep / completeness checklist

- [x] Every `/api/` route in `Watch-PvssLog.ps1` documented (§3)
- [x] All 14 config keys + CLI SamplePerPattern range mismatch noted (§1–2)
- [x] All 23 rule Ids listed (§4)
- [x] Hand-written Process-LogLine / Build-Findings blocks mapped (§5)
- [x] Log discovery + FileShare.ReadWrite (§6)
- [x] ui\ asset list (§7)
- [x] PS → C# map for T5–T7 / T9 (§8)

**Non-goals for 0.5.0:** Blazor; cross-platform; Findings window-scaling; startup-plume; absolute dashboard From/To; chart ladder; Detections UI polish; catch-up % feel; dual-render unify; **Entire-cache**.
