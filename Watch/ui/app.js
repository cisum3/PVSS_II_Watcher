/* PVSS Log Watch UI — pulse/section/manager client */
(function () {
  'use strict';

  var SEVS = ['FATAL', 'SEVERE', 'ERROR', 'WARNING', 'INFO'];
  var AREAS = ['SYS', 'IMPL', 'CTRL', 'PARAM', 'OTHER'];
  var SEV_COLORS = {
    FATAL: '#E00000',
    SEVERE: '#C000A0',
    ERROR: '#B00040',
    WARNING: '#E07000',
    INFO: '#008000'
  };

  var state = {
    running: false,
    starting: false,
    paused: false,
    windowEntire: false,
    lastMinutes: 60,
    refreshSeconds: 3,
    loadingPollMs: 500,
    awaitingLoad: false,
    sawLoading: false,
    loadRequestDone: false,
    severities: { FATAL: true, SEVERE: true, ERROR: true, WARNING: true, INFO: false },
    areas: { SYS: true, IMPL: true, CTRL: true, PARAM: true, OTHER: true },
    generation: null,
    sectionGeneration: {},
    selectedManager: null,
    activeView: 'overview',
    pulse: null,
    pollTimer: null,
    polling: false,
    lastPulseAt: null,
    chartVolume: null,
    chartBacnet: null,
    managersCache: null,
    mgrListCollapsed: false,
    useMock: /[?&]mock=1(?:&|$)/.test(location.search) || location.protocol === 'file:'
  };

  function $(id) { return document.getElementById(id); }

  function qsPulse() {
    var p = new URLSearchParams();
    if (state.windowEntire) p.set('window', 'entire');
    else p.set('lastMinutes', String(state.lastMinutes));
    var sev = SEVS.filter(function (s) { return state.severities[s]; });
    p.set('severities', sev.join(','));
    var areas = AREAS.filter(function (a) { return state.areas[a]; });
    p.set('areas', areas.join(','));
    return p.toString();
  }

  function mockPulse() {
    return {
      generation: 1,
      window: { mode: 'minutes', lastMinutes: 60, first: '2026.09.05 14:00:00.000', last: '2026.09.05 15:02:00.000' },
      loading: false,
      loadProgressPct: 0,
      loadMessage: '',
      paused: false,
      tailRunning: true,
      rotated: false,
      lastError: null,
      logPath: 'C:\\GMSprojects\\Demo\\log\\PVSS_II.log',
      fileLength: 42000000,
      findings: [
        'BACnet device status chatter: 1,200 Failed and 980 OK transitions (85 unique devices Failed).',
        'Project lifecycle (pmon): up=2, stopped=1, shutdown cmds=1, START_MODE=2.',
        'CNS volume: ResolveNodes=140, ReducedFunction=12, ICns=4.'
      ],
      severityCounts: { FATAL: 2, SEVERE: 180, ERROR: 40, WARNING: 920, INFO: 12000 },
      moduleHeadlines: {
        bacnet: { failed: 1200, ok: 980, endedFailed: 42, objectList: 15, collectTrend: 450, timeSync: 80, collectTrendProps: 120, timeSyncProps: 40 },
        cns: { resolveNodes: 140, reducedFunction: 12, tryRenew: 3 },
        coho: { stuck: 8 },
        apogee: { events: 22, updatePoints: 11, drvLines: 800, trendOverflow: 400, trendSeq: 410, alertId: 90, queryTimeout: 40, getDataFail: 50 },
      },
      topManagers: [
        { name: 'WCCOAGmsBACnet', count: 8500 },
        { name: 'WCCOAGmsCoHoMngr', count: 2100 },
        { name: 'Siemens.Gms.ApplicationFramework', count: 900 },
        { name: 'Site.CustomDriver', count: 400 }
      ],
      series: {
        granularity: 'minute',
        byMinute: [
          { t: '2026.09.05 15:00', FATAL: 0, SEVERE: 2, ERROR: 1, WARNING: 10, INFO: 80, bacFailed: 5, bacOk: 4, projectRestart: 1 },
          { t: '2026.09.05 15:01', FATAL: 0, SEVERE: 4, ERROR: 0, WARNING: 12, INFO: 90, bacFailed: 8, bacOk: 6, projectRestart: 0 },
          { t: '2026.09.05 15:02', FATAL: 1, SEVERE: 3, ERROR: 2, WARNING: 8, INFO: 70, bacFailed: 3, bacOk: 7, projectRestart: 0 }
        ]
      },
      projectLifecycle: {
        up: 2, stopped: 1, shutdown: 1, startMode: 2, capped: false,
        cycles: [
          {
            up: '2026.09.05 13:00:00.000', upImplied: true,
            shutdown: '2026.09.05 14:10:00.100', stopped: '2026.09.05 14:10:45.200',
            nextUp: '2026.09.05 14:22:01.000',
            uptime: '1h 10m', stopDuration: '45s', downtime: '11m 16s', stillUp: false
          },
          {
            up: '2026.09.05 14:22:01.000', upImplied: false,
            shutdown: null, stopped: null, nextUp: null,
            uptime: '38m', stopDuration: '', downtime: '', stillUp: true
          }
        ]
      }
    };
  }

  function mockSection(name) {
    if (name === 'patterns') {
      return {
        generation: 1,
        patternsBySeverity: {
          FATAL: [{ pattern: 'Emergency stop <NUM>', count: 2, first: '2026.09.05 14:10:00.000', last: '2026.09.05 15:02:00.000', samples: ['… FATAL Emergency stop 12345'] }],
          SEVERE: [{ pattern: 'UpdatePoints failed PPCL=<ID>', count: 11, first: '2026.09.05 14:00:00.000', last: '2026.09.05 15:01:00.000', samples: ['… SEVERE UpdatePoints'] }],
          ERROR: [],
          WARNING: [{ pattern: 'Could not get object list device <N>', count: 15, first: '2026.09.05 13:00:00.000', last: '2026.09.05 14:55:00.000', samples: ['… WARNING'] }]
        }
      };
    }
    if (name === 'managers') {
      return {
        generation: 1,
        managers: [
          { name: 'WCCOAGmsBACnet', count: 8500, severities: { FATAL: 0, SEVERE: 20, ERROR: 5, WARNING: 200, INFO: 8275 } },
          { name: 'WCCOAGmsCoHoMngr', count: 2100, severities: { FATAL: 0, SEVERE: 40, ERROR: 10, WARNING: 100, INFO: 1950 } },
          { name: 'Siemens.Gms.ApplicationFramework', count: 900, severities: { FATAL: 0, SEVERE: 5, ERROR: 2, WARNING: 80, INFO: 813 } },
          { name: 'Site.CustomDriver', count: 400, severities: { FATAL: 2, SEVERE: 30, ERROR: 20, WARNING: 50, INFO: 298 } }
        ]
      };
    }
    if (name === 'bacnet') {
      return {
        generation: 1,
        bacnet: {
          failed: 1200, ok: 980, endedFailed: 42, endedOk: 60, flappers: 7, objectList: 15,
          collectTrend: 450, timeSync: 80, collectTrendProps: 120, timeSyncProps: 40,
          collectTrendSample: 'Error Code 70442 for Property "System4:GmsDevice_1_512_86887595.Log_Enable" and Command "BACnetCollectTrend"',
          timeSyncSample: 'Error Code 70443 for Property "System4:GmsDevice_1_7194_33561626.Local_Time" and Command "BACnetTimeSync"',
          collectTrendCodes: [{ code: '70442', count: 450 }],
          timeSyncCodes: [{ code: '70443', count: 70 }, { code: '70442', count: 10 }],
          collectTrendTop: [
            { property: 'System4:GmsDevice_1_512_86887595.Log_Enable', count: 12 },
            { property: 'System4:GmsDevice_1_512_86887597.Log_Enable', count: 9 }
          ],
          timeSyncTop: [
            { property: 'System4:GmsDevice_1_7194_33561626.Local_Time', count: 8 }
          ],
          failedSample: 'Device 101 Status is now Failed',
          okSample: 'Device 101 Status is now OK',
          objectListSample: 'Could not get object list for device 55',
          activity: [
            { device: '101', failed: 40, ok: 38, flips: 12, last: 'Failed' },
            { device: '202', failed: 22, ok: 20, flips: 8, last: 'OK' }
          ],
          endedFailedList: [
            { device: '101', failed: 40, ok: 38, flips: 12 },
            { device: '303', failed: 5, ok: 0, flips: 1 }
          ],
          objectListTop: [{ device: '55', count: 8 }, { device: '66', count: 4 }]
        }
      };
    }
    if (name === 'cns') {
      return {
        generation: 1,
        cns: {
          resolveNodes: 140, reducedFunction: 12, icns: 4, tryRenew: 3,
          patterns: [{ pattern: 'ResolveNodes …', count: 140, first: '…', last: '…', samples: ['…'] }]
        }
      };
    }
    if (name === 'coho') {
      return { generation: 1, coho: { stuck: 8, sample: '… got stuck', topNames: [{ name: 'DiscoveryLoc:X', count: 5 }] } };
    }
    if (name === 'apogee') {
      return {
        generation: 1,
        apogee: {
          events: 22, updatePoints: 11, repetition: 2, other: 9, uniquePpcl: 4,
          sample: '… CoHo.Apogee …',
          topPpcl: [{ name: 'PROG_A', count: 6 }, { name: 'PROG_B', count: 3 }],
          drvLines: 800, trendOverflow: 400, trendSeq: 410, alertId: 90, queryTimeout: 40, getDataFail: 50,
          trendDevices: 12, trendNames: 80, getDataDevices: 5,
          trendSample: 'Trend buffer overflow for trend X:0  in device ETHERNET|NODE.',
          alertSample: 'AlertService, sendAck, AlertID GMSAPOGEE_2_123 is not known',
          timeoutSample: 'pending answer run into timeout - aborting single query',
          getDataSample: 'Failed to get data for object X on device ETHERNET|NODE, Status = Timeout…',
          topTrendDevices: [{ device: 'ETHERNET|NODE1', count: 40 }, { device: 'ETHERNET|NODE2', count: 22 }],
          topTrends: [{ trend: 'BLDG.POINT:0', count: 12 }],
          topGetDataDevices: [{ device: 'ETHERNET|NODE3', count: 18 }]
        }
      };
    }
    if (name === 'detections') {
      return {
        generation: 1,
        // Groups and rules arrive worst-first by score, so this mirrors that order. Between
        // them these rules cover every render branch: measures vs plain count, a folded single
        // severity vs a breakdown, collapsed vs tabulated buckets, and over vs under threshold.
        detections: [{
          group: 'Driver', total: 922, score: 140940,
          rules: [{
            id: 'driver.errorCode', label: 'Driver returned error code', count: 783,
            first: '2026.09.04 16:00:17.995', last: '2026.09.04 16:00:47.243',
            findingAt: 250, over: 3.13, spanSec: 60, rate: 46980, score: 140940,
            sample: 'IStyle.IndValues: The Driver returned Error Code 70442 for Property "System4:GmsDevice_1_513.Log_Enable"',
            severities: { SEVERE: 783 },
            buckets: {
              code: { distinct: 1, capped: false, top: [{ value: '70442', count: 783 }] },
              manager: { distinct: 1, capped: false, top: [{ value: 'WCCOAGmsCoHoMngr(7)', count: 783 }] }
            }
          }, {
            id: 'state.unexpected', label: 'Unexpected state', count: 139,
            first: '2026.09.04 12:34:20.716', last: '2026.09.04 16:42:39.612',
            findingAt: 500, over: 0.28, spanSec: 14899, rate: 33.6, score: 35.8,
            sample: 'Unexpected state, DrvManager, gotAlertConfigAnswer, AlertConfig missing for PeriphAddr 7261.33561693',
            severities: { SEVERE: 5, WARNING: 133, INFO: 1 },
            buckets: {
              method: {
                distinct: 7, capped: false, top: [
                  { value: 'gotAlertConfigAnswer', count: 52 },
                  { value: 'SendAnswer', count: 49 },
                  { value: 'setAlert', count: 24 }
                ]
              }
            }
          }]
        }, {
          group: 'Framework', total: 19037, score: 10551,
          rules: [{
            id: 'afw.traceRepetition', label: 'Repeated trace', count: 19037,
            first: '2026.09.04 12:37:26.855', last: '2026.09.04 18:02:11.100',
            findingAt: 500, over: 38.07, spanSec: 19485, rate: 3517, score: 10551,
            sample: '^4:Repetition (#=1) of a former trace (see creation time …)',
            severities: { SEVERE: 19037 },
            measures: { repeats: 10484490, worstRun: 1709 },
            buckets: {
              manager: { distinct: 13, capped: false, top: [{ value: 'WCCOACComMgr (99)', count: 4828 }] },
              subArea: { distinct: 12, capped: false, top: [{ value: 'Orch.Alarm', count: 7276 }] }
            }
          }]
        }]
      };
    }
    if (name === 'perf') {
      return {
        generation: 1,
        perfCategories: [{ name: 'Timeout', count: 6 }, { name: 'CNS/Resolve', count: 140 }],
        unparsedLines: 120,
        parsedLines: 50000,
        health: { version: '0.2.0', author: 'Cisum', port: 8787, refreshSeconds: 3,
          defaults: { lastMinutes: 60, windowEntire: false, severities: ['FATAL', 'SEVERE', 'ERROR', 'WARNING'] } }
      };
    }
    return { generation: 1 };
  }

  function mockManager(name) {
    return {
      generation: 1,
      name: name,
      count: 400,
      severities: { FATAL: 2, SEVERE: 30, ERROR: 20, WARNING: 50, INFO: 298 },
      patternsBySeverity: {
        FATAL: [{ pattern: 'Site fault <NUM>', count: 2, first: 'a', last: 'b', samples: ['…'] }],
        SEVERE: [{ pattern: 'Driver delay <NUM> ms', count: 12, first: 'a', last: 'b', samples: ['…'] }],
        ERROR: [],
        WARNING: [{ pattern: 'Retry device <N>', count: 20, first: 'a', last: 'b', samples: ['…'] }]
      }
    };
  }

  function apiGet(path) {
    if (state.useMock) {
      return Promise.resolve().then(function () {
        if (path.indexOf('/api/pulse') === 0) return { status: 200, json: mockPulse() };
        if (path.indexOf('/api/section') === 0) {
          var sn = (path.match(/name=([^&]+)/) || [])[1] || 'patterns';
          return { status: 200, json: mockSection(decodeURIComponent(sn)) };
        }
        if (path.indexOf('/api/manager') === 0) {
          var mn = (path.match(/name=([^&]+)/) || [])[1] || '';
          return { status: 200, json: mockManager(decodeURIComponent(mn)) };
        }
        if (path.indexOf('/api/health') === 0) {
          return { status: 200, json: { ok: true, version: '0.2.0', author: 'Cisum', mock: true, prefillPath: '',
            refreshSeconds: 3,
            defaults: { lastMinutes: 60, windowEntire: false, severities: ['FATAL', 'SEVERE', 'ERROR', 'WARNING'] } } };
        }
        return { status: 404, json: null };
      });
    }
    return fetch(path, { headers: { Accept: 'application/json' } }).then(function (r) {
      if (r.status === 304) return { status: 304, json: null };
      if (!r.ok) {
        return r.text().then(function (t) {
          throw new Error(t || ('HTTP ' + r.status));
        });
      }
      return r.json().then(function (j) { return { status: 200, json: j }; });
    });
  }

  function apiPost(path, body) {
    if (state.useMock) {
      return Promise.resolve({ ok: true, json: { ok: true, mock: true } });
    }
    return fetch(path, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
      body: JSON.stringify(body || {})
    }).then(function (r) {
      return r.json().then(function (j) {
        if (!r.ok) throw new Error((j && j.error) || ('HTTP ' + r.status));
        return { ok: true, json: j };
      }, function () {
        if (!r.ok) throw new Error('HTTP ' + r.status);
        return { ok: true, json: {} };
      });
    });
  }

  function setBanner(which, text) {
    var el = $(which);
    if (!el) return;
    if (!text) { el.hidden = true; el.textContent = ''; return; }
    el.hidden = false;
    el.textContent = text;
  }

  // The host is mid-scan: a Start is in flight, we are waiting for the first loading pulse,
  // or the host says it is still catching up.
  function isCatchingUp() {
    return !!(state.starting || state.awaitingLoad || (state.pulse && state.pulse.loading));
  }

  // Reseeding the window during a catch-up left the UI describing one window while the host
  // finished loading another, so lock those controls until the scan settles.
  // Guard as well as disable: the controls are re-enabled from pulse, so a keypress can land
  // in the gap before updateChromeButtons() next runs. Mock mode has no host to desync from.
  function windowLocked() {
    return isCatchingUp() && !state.useMock;
  }

  function setWindowControlsEnabled(on) {
    var off = !on;
    document.querySelectorAll('#windowPresets .chip, #customWindowUnit .unit-chip').forEach(function (b) {
      b.disabled = off;
    });
    var v = $('customWindowValue'); if (v) v.disabled = off;
    var a = $('btnApplyWindow'); if (a) a.disabled = off;
    var w = $('windowPresets');
    if (w) w.title = off ? 'Locked while the host is loading a window' : '';
  }

  function updateChromeButtons() {
    $('btnStart').disabled = state.running || state.starting;
    $('btnPause').disabled = !state.running || state.paused || state.starting;
    $('btnResume').disabled = !state.running || !state.paused || state.starting;
    $('btnRestart').disabled = (!state.running && !state.pulse && !state.starting);
    var snapOk = !!state.pulse && !state.starting && !(state.pulse && state.pulse.loading);
    $('btnSnapshot').disabled = !snapOk;
    if (!snapOk && $('snapFormats') && !$('snapFormats').hidden) closeSnapFormats();
    $('logPath').readOnly = (state.running || state.starting) && !state.useMock;
    setWindowControlsEnabled(!isCatchingUp());
  }

  function triggerDownload(blob, fileName) {
    var url = URL.createObjectURL(blob);
    var a = document.createElement('a');
    a.href = url;
    a.download = fileName;
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(function () { URL.revokeObjectURL(url); }, 1500);
  }

  var SNAP_FORMATS = {
    html: { ext: 'html', mime: 'text/html', accept: 'text/html' },
    text: { ext: 'txt', mime: 'text/plain', accept: 'text/plain' },
    json: { ext: 'json', mime: 'application/json', accept: 'application/json' }
  };

  function openSnapFormats() {
    if ($('btnSnapshot').disabled) return;
    $('btnSnapshot').hidden = true;
    $('snapFormats').hidden = false;
    var first = $('snapFormats').querySelector('.chip');
    if (first) first.focus();
  }

  function closeSnapFormats() {
    $('snapFormats').hidden = true;
    $('btnSnapshot').hidden = false;
  }

  function downloadSnapshot(format) {
    var fmt = SNAP_FORMATS[format] ? format : 'html';
    var stamp = (function () {
      var d = new Date();
      function p(n) { return (n < 10 ? '0' : '') + n; }
      return '' + d.getFullYear() + p(d.getMonth() + 1) + p(d.getDate()) + '_' +
        p(d.getHours()) + p(d.getMinutes()) + p(d.getSeconds());
    })();
    var fileName = 'PVSS_Log_Watch_Snapshot_' + stamp + '.' + SNAP_FORMATS[fmt].ext;

    if (state.useMock) {
      var body;
      if (fmt === 'json') {
        body = JSON.stringify(mockPulse(), null, 2);
      } else if (fmt === 'text') {
        body = [
          '================================================================================',
          ' PVSS / WinCC OA Log Analysis Report (mock)',
          '================================================================================',
          'Open via Run-Watch.cmd for a full report from live analysis.',
          '',
          JSON.stringify(mockPulse(), null, 2)
        ].join('\r\n');
      } else {
        body = [
          '<!DOCTYPE html><html><head><meta charset="utf-8" /><title>PVSS Log Watch Snapshot (mock)</title>',
          '<style>body{font-family:Segoe UI,sans-serif;background:#0f1923;color:#fff;padding:1.25rem}',
          'h1{color:#009999} .meta{color:#aaaa96}</style></head><body>',
          '<h1>PVSS Log Watch — mock snapshot</h1>',
          '<p class="meta">Open via Run-Watch.cmd for a full styled snapshot from live analysis.</p>',
          '<pre>' + JSON.stringify(mockPulse(), null, 2).replace(/</g, '&lt;') + '</pre>',
          '</body></html>'
        ].join('');
      }
      triggerDownload(new Blob([body], { type: SNAP_FORMATS[fmt].mime + ';charset=utf-8' }), fileName);
      return;
    }

    setBanner('bannerError', '');
    var url = '/api/snapshot?format=' + fmt + '&' + qsPulse();
    fetch(url, { headers: { Accept: SNAP_FORMATS[fmt].accept } }).then(function (r) {
      if (!r.ok) {
        return r.json().then(function (j) {
          throw new Error((j && j.error) || ('HTTP ' + r.status));
        }, function () {
          throw new Error('HTTP ' + r.status);
        });
      }
      var cd = r.headers.get('Content-Disposition') || '';
      var m = /filename=\"?([^\";]+)\"?/i.exec(cd);
      if (m && m[1]) fileName = m[1];
      return r.blob();
    }).then(function (blob) {
      triggerDownload(blob, fileName);
    }).catch(function (e) {
      setBanner('bannerError', 'Snapshot failed: ' + (e.message || e));
    });
  }

  function setStatus(html) {
    $('statusLine').innerHTML = html;
  }

  function selectedSeverities() {
    return SEVS.filter(function (s) { return state.severities[s]; });
  }

  function selectedAreas() {
    return AREAS.filter(function (a) { return state.areas[a]; });
  }

  function renderWindowSpan(w) {
    var el = $('overviewWindow');
    if (!el) return;
    if (!w || (!w.first && !w.last)) {
      el.hidden = true;
      el.textContent = '';
      return;
    }
    var mode = (w.mode === 'entire')
      ? 'Entire file'
      : ('Last ' + (w.lastMinutes || state.lastMinutes || '?') + ' minutes of file');
    el.hidden = false;
    el.textContent = mode + '  ·  ' + (w.first || '—') + '  →  ' + (w.last || '—');
  }

  function renderFindings(list) {
    var ul = $('findingsList');
    ul.innerHTML = '';
    (list || []).forEach(function (f) {
      var li = document.createElement('li');
      li.textContent = f;
      ul.appendChild(li);
    });
  }

  function renderProjectRestarts(pl) {
    var panel = $('projectRestartsPanel');
    var meta = $('projectRestartsMeta');
    var tbody = $('projectRestartsTable') && $('projectRestartsTable').querySelector('tbody');
    if (!panel || !meta || !tbody) return;
    var cycles = (pl && pl.cycles) ? pl.cycles : [];
    var up = pl ? (pl.up || 0) : 0;
    var stopped = pl ? (pl.stopped || 0) : 0;
    var shutdown = pl ? (pl.shutdown || 0) : 0;
    var startMode = pl ? (pl.startMode || 0) : 0;
    var hasSignal = cycles.length > 0 || up > 0 || stopped > 0 || shutdown > 0;
    if (!hasSignal) {
      panel.hidden = true;
      tbody.innerHTML = '';
      meta.textContent = '';
      return;
    }
    panel.hidden = false;
    var cap = pl && pl.capped ? ' (events capped at 200)' : '';
    meta.textContent = 'up=' + Number(up).toLocaleString() +
      '  ·  stopped=' + Number(stopped).toLocaleString() +
      '  ·  shutdown=' + Number(shutdown).toLocaleString() +
      '  ·  START_MODE=' + Number(startMode).toLocaleString() +
      '  ·  cycles=' + cycles.length + cap +
      '. Uptime = up→shutdown; stop = shutdown→stopped; downtime = stopped→next up. START_MODE counted only.';
    tbody.innerHTML = '';
    if (!cycles.length) {
      var empty = document.createElement('tr');
      empty.innerHTML = '<td colspan="7" class="meta">Counts present but no cycle timestamps retained.</td>';
      tbody.appendChild(empty);
      return;
    }
    cycles.forEach(function (c) {
      var tr = document.createElement('tr');
      var upLabel = String(c.up || '');
      if (c.upImplied) upLabel += ' (window start)';
      var note = '';
      if (c.stillUp && c.nextUp) note = 'no shutdown before next up';
      else if (c.stillUp) note = 'still up';
      else if (c.stillDown || (c.stopped && !c.nextUp)) note = 'still down';
      else if (!c.shutdown && c.stopped) note = 'no shutdown line';
      tr.innerHTML =
        '<td class="mono kind-up">' + escapeHtml(upLabel) + '</td>' +
        '<td class="mono kind-shutdown">' + escapeHtml(String(c.shutdown || '')) + '</td>' +
        '<td>' + escapeHtml(String(c.uptime || '')) + '</td>' +
        '<td class="mono kind-stopped">' + escapeHtml(String(c.stopped || '')) + '</td>' +
        '<td>' + escapeHtml(String(c.stopDuration || '')) + '</td>' +
        '<td>' + escapeHtml(String(c.downtime || '')) + '</td>' +
        '<td class="meta">' + escapeHtml(note) + '</td>';
      tbody.appendChild(tr);
    });
  }

  function renderKpis(counts) {
    var row = $('kpiRow');
    row.innerHTML = '';
    SEVS.forEach(function (s) {
      var d = document.createElement('div');
      d.className = 'kpi';
      d.setAttribute('data-sev', s);
      d.innerHTML = '<div class="label">' + s + '</div><div class="value">' +
        ((counts && counts[s]) != null ? Number(counts[s]).toLocaleString() : '0') + '</div>';
      row.appendChild(d);
    });
  }

  function renderMgrStrip(list) {
    var el = $('mgrStrip');
    el.innerHTML = '';
    (list || []).slice(0, 12).forEach(function (m) {
      var p = document.createElement('button');
      p.type = 'button';
      p.className = 'mgr-pill';
      p.innerHTML = '<strong>' + escapeHtml(m.name) + '</strong>' + Number(m.count).toLocaleString();
      p.addEventListener('click', function () {
        state.selectedManager = m.name;
        showView('managers');
        loadManagerDetail(m.name);
      });
      el.appendChild(p);
    });
  }

  function escapeHtml(s) {
    return String(s).replace(/[&<>"']/g, function (c) {
      return ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c];
    });
  }

  function ensureCharts() {
    if (typeof Chart === 'undefined') return;
    Chart.defaults.color = '#879BAA';
    Chart.defaults.borderColor = 'rgba(135,155,170,0.25)';
    Chart.defaults.font.family = 'Segoe UI, Candara, Calibri, sans-serif';
  }

  function formatChartLabel(t, gran) {
    if (!t) return '';
    if (gran === 'day') {
      return t.length >= 10 ? t.slice(0, 10) : t;
    }
    if (gran === 'hour') {
      if (t.length >= 13) return t.slice(5, 13); // MM.dd HH
      return t;
    }
    if (t.length >= 16) return t.slice(5, 16); // MM.dd HH:mm for multi-hour readability
    return t;
  }

  function granLabel(gran) {
    if (gran === 'day') return 'day';
    if (gran === 'hour') return 'hour';
    return 'minute';
  }

  function projectRestartPlugin() {
    return {
      id: 'projectRestartLines',
      afterDatasetsDraw: function (chart) {
        var flags = (chart.options && chart.options.plugins && chart.options.plugins.projectRestarts) || [];
        if (!flags.length) return;
        var xScale = chart.scales.x;
        var yScale = chart.scales.y;
        if (!xScale || !yScale) return;
        var ctx = chart.ctx;
        for (var i = 0; i < flags.length; i++) {
          if (!flags[i]) continue;
          var x = xScale.getPixelForValue(i);
          if (!isFinite(x)) continue;
          ctx.save();
          ctx.beginPath();
          ctx.strokeStyle = 'rgba(224, 160, 0, 0.9)';
          ctx.lineWidth = 2;
          ctx.setLineDash([5, 4]);
          ctx.moveTo(x, yScale.top);
          ctx.lineTo(x, yScale.bottom);
          ctx.stroke();
          ctx.restore();
        }
      }
    };
  }

  function updateCharts(series) {
    ensureCharts();
    var rows = (series && series.byMinute) || [];
    var gran = (series && series.granularity) || 'minute';
    var restartFlags = rows.map(function (r) { return !!(r.projectRestart); });
    var hasRestart = restartFlags.some(function (v) { return v; });
    var hint = $('chartRestartHint');
    if (hint) hint.hidden = !hasRestart;
    var sevList = selectedSeverities().filter(function (s) { return s !== 'INFO' || state.severities.INFO; });
    var labels = rows.map(function (r) { return formatChartLabel(r.t, gran); });
    var hasVol = rows.some(function (r) {
      return sevList.some(function (s) { return (r[s] || 0) > 0; });
    });
    var volTitle = $('chartVolumeTitle');
    if (volTitle) volTitle.textContent = 'Message volume by ' + granLabel(gran);
    $('chartVolumeEmpty').hidden = hasVol;
    if (typeof Chart !== 'undefined') {
      var datasets = hasVol ? sevList.map(function (s) {
        return {
          label: s,
          data: rows.map(function (r) { return r[s] || 0; }),
          backgroundColor: SEV_COLORS[s],
          stack: 's'
        };
      }) : [];
      var volOpts = {
        responsive: true,
        maintainAspectRatio: false,
        plugins: {
          legend: { display: hasVol, position: 'bottom', labels: { boxWidth: 10 } },
          projectRestarts: hasVol ? restartFlags : []
        },
        scales: {
          x: { stacked: true, ticks: { autoSkip: true, maxTicksLimit: 12, maxRotation: 45, minRotation: 0 } },
          y: { stacked: true, beginAtZero: true }
        }
      };
      if (!state.chartVolume) {
        state.chartVolume = new Chart($('chartVolume'), {
          type: 'bar',
          data: { labels: hasVol ? labels : [], datasets: datasets },
          options: volOpts,
          plugins: [projectRestartPlugin()]
        });
      } else {
        state.chartVolume.data.labels = hasVol ? labels : [];
        state.chartVolume.data.datasets = datasets;
        state.chartVolume.options.plugins.legend.display = hasVol;
        state.chartVolume.options.plugins.projectRestarts = hasVol ? restartFlags : [];
        state.chartVolume.update('none');
      }
    }

    var hasBac = rows.some(function (r) { return (r.bacFailed || 0) + (r.bacOk || 0) > 0; });
    var hasSevFallback = !hasBac && rows.some(function (r) { return (r.SEVERE || 0) > 0; });
    var hasLine = hasBac || hasSevFallback;
    var bacTitle = $('chartBacnetTitle');
    if (bacTitle) {
      bacTitle.textContent = hasBac
        ? ('BACnet Failed / OK by ' + granLabel(gran))
        : ('SEVERE volume by ' + granLabel(gran));
    }
    $('chartBacnetEmpty').hidden = hasLine;
    if (typeof Chart !== 'undefined') {
      var ds2 = [];
      if (hasBac) {
        ds2 = [
          { label: 'Failed', data: rows.map(function (r) { return r.bacFailed || 0; }), borderColor: SEV_COLORS.SEVERE, backgroundColor: 'transparent', tension: 0.2, pointRadius: rows.length > 80 ? 0 : 2 },
          { label: 'OK', data: rows.map(function (r) { return r.bacOk || 0; }), borderColor: SEV_COLORS.INFO, backgroundColor: 'transparent', tension: 0.2, pointRadius: rows.length > 80 ? 0 : 2 }
        ];
      } else if (hasSevFallback) {
        ds2 = [
          { label: 'SEVERE', data: rows.map(function (r) { return r.SEVERE || 0; }), borderColor: SEV_COLORS.SEVERE, backgroundColor: 'transparent', tension: 0.2, pointRadius: rows.length > 80 ? 0 : 2 }
        ];
      }
      var bacOpts = {
        responsive: true,
        maintainAspectRatio: false,
        plugins: {
          legend: { display: hasLine, position: 'bottom', labels: { boxWidth: 10 } },
          projectRestarts: hasLine ? restartFlags : []
        },
        scales: {
          x: { ticks: { autoSkip: true, maxTicksLimit: 12, maxRotation: 45, minRotation: 0 } },
          y: { beginAtZero: true }
        }
      };
      if (!state.chartBacnet) {
        state.chartBacnet = new Chart($('chartBacnet'), {
          type: 'line',
          data: { labels: hasLine ? labels : [], datasets: ds2 },
          options: bacOpts,
          plugins: [projectRestartPlugin()]
        });
      } else {
        state.chartBacnet.data.labels = hasLine ? labels : [];
        state.chartBacnet.data.datasets = ds2;
        state.chartBacnet.options.plugins.legend.display = hasLine;
        state.chartBacnet.options.plugins.projectRestarts = hasLine ? restartFlags : [];
        state.chartBacnet.update('none');
      }
    }
  }

  function applyPulse(p) {
    state.pulse = p;
    state.generation = p.generation;
    state.paused = !!p.paused;
    state.running = !!(p.tailRunning || p.loading || state.useMock);
    if (p.logPath && !$('logPath').value) $('logPath').value = p.logPath;
    if (p.loading) {
      state.sawLoading = true;
      state.loadRequestDone = false;
    } else if (state.awaitingLoad && (state.sawLoading || state.loadRequestDone)) {
      state.awaitingLoad = false;
      state.sawLoading = false;
      state.loadRequestDone = false;
    }

    $('idleHint').hidden = true;
    $('overviewBody').hidden = false;
    var loadBanner = '';
    if (p.loading) {
      loadBanner = p.loadMessage || (
        (state.windowEntire ? 'Loading entire file' : ('Loading last ' + state.lastMinutes + ' minutes')) +
        '... ' + (p.loadProgressPct != null ? p.loadProgressPct : 0) + '%'
      );
    }
    setBanner('bannerLoading', loadBanner);
    setBanner('bannerRotate', p.rotated ? 'Log rotated — counters reset' : '');
    setBanner('bannerError', p.lastError || '');

    renderWindowSpan(p.window);
    renderFindings(p.findings);
    renderProjectRestarts(p.projectLifecycle);
    renderKpis(p.severityCounts);
    renderMgrStrip(p.topManagers);
    updateCharts(p.series);

    var age = 'just now';
    state.lastPulseAt = Date.now();
    var mode = state.windowEntire ? 'Entire file' : (state.lastMinutes + 'm');
    var run = p.loading
      ? ('<span class="warn">loading ' + (p.loadProgressPct != null ? p.loadProgressPct : 0) + '%</span>')
      : (p.paused ? '<span class="warn">paused</span>' : '<span class="ok">tailing</span>');
    if (p.lastError) run = '<span class="err">error</span>';
    setStatus(run + ' · window ' + mode + ' · gen ' + p.generation + ' · updated ' + age +
      (state.useMock ? ' · <span class="warn">mock</span>' : ''));
    updateChromeButtons();
  }

  function renderPatternList(bySev) {
    var host = $('patternsBody');
    host.innerHTML = '';
    var shown = 0;
    ['FATAL', 'SEVERE', 'ERROR', 'WARNING'].forEach(function (sev) {
      if (!state.severities[sev]) return; // filtered out — omit pane (do not look like "no logs")
      shown++;
      var block = document.createElement('div');
      block.className = 'pattern-block';
      var list = (bySev && bySev[sev]) || [];
      block.innerHTML = '<h3 style="color:' + SEV_COLORS[sev] + '">' + sev +
        '<span class="meta">(' + list.length + ')</span></h3>';
      if (!list.length) {
        block.innerHTML += '<p class="meta">No patterns in the current window</p>';
      } else {
        var table = document.createElement('table');
        table.className = 'data';
        table.innerHTML = '<thead><tr><th>Count</th><th>First</th><th>Last</th><th>Pattern</th></tr></thead>';
        var tb = document.createElement('tbody');
        list.forEach(function (row) {
          var tr = document.createElement('tr');
          tr.innerHTML = '<td>' + Number(row.count).toLocaleString() + '</td><td class="meta">' +
            escapeHtml(row.first || '') + '</td><td class="meta">' + escapeHtml(row.last || '') +
            '</td><td class="mono">' + escapeHtml(row.pattern || '') + '</td>';
          tb.appendChild(tr);
        });
        table.appendChild(tb);
        block.appendChild(table);
      }
      host.appendChild(block);
    });
    if (!shown) {
      host.innerHTML = '<p class="meta">No severity filters enabled — turn on FATAL / SEVERE / ERROR / WARNING above to see patterns.</p>';
    }
  }

  function updateMgrListCollapseUi() {
    var panel = $('mgrListPanel');
    var btn = $('btnToggleMgrList');
    var summary = $('mgrListSummary');
    var hasSelection = !!state.selectedManager;
    if (!hasSelection) {
      state.mgrListCollapsed = false;
    }
    panel.classList.toggle('is-collapsed', !!state.mgrListCollapsed);
    btn.hidden = !hasSelection;
    summary.hidden = !hasSelection;
    if (hasSelection) {
      summary.textContent = 'Selected: ' + state.selectedManager;
      btn.textContent = state.mgrListCollapsed ? 'Show manager list' : 'Hide manager list';
      btn.setAttribute('aria-expanded', state.mgrListCollapsed ? 'false' : 'true');
    }
  }

  function setMgrListCollapsed(collapsed) {
    state.mgrListCollapsed = !!collapsed && !!state.selectedManager;
    updateMgrListCollapseUi();
    if (state.mgrListCollapsed) {
      var detail = $('mgrDetail');
      if (detail && !detail.hidden) {
        try { detail.scrollIntoView({ behavior: 'smooth', block: 'start' }); } catch (e) { detail.scrollIntoView(true); }
      }
    }
  }

  function renderManagersTable(managers) {
    state.managersCache = managers || [];
    var tb = $('mgrTable').querySelector('tbody');
    tb.innerHTML = '';
    state.managersCache.forEach(function (m) {
      var tr = document.createElement('tr');
      if (state.selectedManager === m.name) tr.className = 'selected';
      var s = m.severities || {};
      tr.innerHTML = '<td>' + Number(m.count).toLocaleString() + '</td><td class="mono">' +
        escapeHtml(m.name) + '</td><td>' + (s.FATAL || 0) + '</td><td>' + (s.SEVERE || 0) +
        '</td><td>' + (s.ERROR || 0) + '</td><td>' + (s.WARNING || 0) + '</td>';
      tr.addEventListener('click', function () {
        state.selectedManager = m.name;
        setMgrListCollapsed(true);
        loadManagerDetail(m.name);
        renderManagersTable(state.managersCache);
      });
      tb.appendChild(tr);
    });
    updateMgrListCollapseUi();
  }

  function renderManagerDetail(data) {
    $('mgrDetail').hidden = false;
    $('mgrDetailTitle').textContent = data.name || state.selectedManager;
    var body = $('mgrDetailBody');
    body.innerHTML = '<p class="meta">Lines: ' + Number(data.count || 0).toLocaleString() + '</p>';
    if (lifecycleHasSignal(data.lifecycle)) {
      var lifeWrap = document.createElement('div');
      lifeWrap.innerHTML = renderLifecycleHtml(data.lifecycle);
      body.appendChild(lifeWrap);
    }
    renderPatternListInto(body, data.patternsBySeverity);
    updateMgrListCollapseUi();
    if (state.mgrListCollapsed) {
      try { $('mgrDetail').scrollIntoView({ behavior: 'smooth', block: 'start' }); } catch (e) { $('mgrDetail').scrollIntoView(true); }
    }
  }

  function renderPatternListInto(host, bySev) {
    var wrap = document.createElement('div');
    var shown = 0;
    ['FATAL', 'SEVERE', 'ERROR', 'WARNING'].forEach(function (sev) {
      if (!state.severities[sev]) return;
      shown++;
      var list = (bySev && bySev[sev]) || [];
      if (!list.length) return;
      var h = document.createElement('h3');
      h.style.color = SEV_COLORS[sev];
      h.textContent = sev;
      wrap.appendChild(h);
      var table = document.createElement('table');
      table.className = 'data';
      table.innerHTML = '<thead><tr><th>Count</th><th>Pattern</th></tr></thead>';
      var tb = document.createElement('tbody');
      list.forEach(function (row) {
        var tr = document.createElement('tr');
        tr.innerHTML = '<td>' + Number(row.count).toLocaleString() + '</td><td class="mono">' +
          escapeHtml(row.pattern || '') + '</td>';
        tb.appendChild(tr);
      });
      table.appendChild(tb);
      wrap.appendChild(table);
    });
    if (!shown) {
      var p = document.createElement('p');
      p.className = 'meta';
      p.textContent = 'No severity filters enabled — turn on FATAL / SEVERE / ERROR / WARNING above.';
      wrap.appendChild(p);
    } else if (!wrap.querySelector('table')) {
      var p2 = document.createElement('p');
      p2.className = 'meta';
      p2.textContent = 'No patterns for the enabled severities in the current window.';
      wrap.appendChild(p2);
    }
    host.appendChild(wrap);
  }

  function renderLifecycleHtml(life, samples) {
    if (!life) return '';
    var rows = life.managers || [];
    var t = life.totals || {};
    var hits = (t.starts || 0) + (t.stops || 0) + (t.restarts || 0) + (t.blocking || 0) + (t.unblocked || 0);
    if (!hits && !rows.length) return '';
    function sampleForSection(raw) {
      if (!raw) return '';
      for (var i = 0; i < rows.length; i++) {
        if (raw.indexOf(rows[i].name) >= 0) return raw;
      }
      return rows.length ? '' : raw;
    }
    var h = '<h2>Manager health (pmon)</h2>';
    h += '<p class="meta">Start/stop from Manager Start PROJ / Manager Stop. Restarts = pmon “Detected stopped manager…”. Blocking = no heartbeat (overloaded / too busy).</p>';
    var bs = sampleForSection(samples && samples.blockingSample);
    var us = sampleForSection(samples && samples.unblockingSample);
    if (bs) h += '<p class="meta mono">' + escapeHtml(bs) + '</p>';
    if (us) h += '<p class="meta mono">' + escapeHtml(us) + '</p>';
    if (rows.length) {
      h += '<table class="data"><thead><tr><th>Manager</th><th>Starts</th><th>Stops</th><th>Restarts</th><th>Blocking</th><th>Unblocked</th></tr></thead><tbody>';
      rows.forEach(function (r) {
        h += '<tr><td class="mono">' + escapeHtml(r.name) + '</td><td>' + r.starts +
          '</td><td>' + r.stops + '</td><td>' + r.restarts +
          '</td><td>' + r.blocking + '</td><td>' + r.unblocked + '</td></tr>';
      });
      h += '</tbody></table>';
    }
    return h;
  }

  function lifecycleHasSignal(life) {
    if (!life || !life.totals) return false;
    var t = life.totals;
    return ((t.starts || 0) + (t.stops || 0) + (t.restarts || 0) + (t.blocking || 0) + (t.unblocked || 0)) > 0;
  }

  function renderBacnet(b) {
    var el = $('bacnetBody');
    var hasSig = b && ((b.failed || 0) + (b.ok || 0) + (b.objectList || 0) + (b.collectTrend || 0) + (b.timeSync || 0) > 0);
    var hasLife = b && lifecycleHasSignal(b.lifecycle);
    if (!hasSig && !hasLife) {
      el.innerHTML = '<p class="meta">No BACnet signals in the current window.</p>';
      return;
    }
    var html = '';
    if (hasSig) {
      html += '<p>Failed transitions: <strong>' + b.failed + '</strong> · OK: <strong>' + b.ok +
        '</strong> · ended Failed: <strong>' + b.endedFailed + '</strong> · ended OK: <strong>' + b.endedOk +
        '</strong> · flappers: <strong>' + b.flappers + '</strong> · object-list: <strong>' + b.objectList + '</strong></p>';
      if (b.failedSample) html += '<p class="meta mono">' + escapeHtml(b.failedSample) + '</p>';

      html += '<h2>Device status activity</h2><table class="data"><thead><tr><th>Device</th><th>Failed</th><th>OK</th><th>Flips</th><th>Last</th></tr></thead><tbody>';
      (b.activity || []).forEach(function (r) {
        html += '<tr><td>' + escapeHtml(r.device) + '</td><td>' + r.failed + '</td><td>' + r.ok +
          '</td><td>' + r.flips + '</td><td>' + escapeHtml(r.last) + '</td></tr>';
      });
      html += '</tbody></table>';
      html += '<h2>Ended Failed</h2><table class="data"><thead><tr><th>Device</th><th>Failed</th><th>OK</th><th>Flips</th></tr></thead><tbody>';
      (b.endedFailedList || []).forEach(function (r) {
        html += '<tr><td>' + escapeHtml(r.device) + '</td><td>' + r.failed + '</td><td>' + r.ok +
          '</td><td>' + r.flips + '</td></tr>';
      });
      html += '</tbody></table>';
      html += '<h2>Object list</h2>';
      if (b.objectListSample) html += '<p class="meta mono">' + escapeHtml(b.objectListSample) + '</p>';
      html += '<table class="data"><thead><tr><th>Device</th><th>Count</th></tr></thead><tbody>';
      (b.objectListTop || []).forEach(function (r) {
        html += '<tr><td>' + escapeHtml(r.device) + '</td><td>' + r.count + '</td></tr>';
      });
      html += '</tbody></table>';

      function cmdBlock(title, blurb, count, propCount, sample, codes, props) {
        var h = '<h2>' + title + '</h2>';
        h += '<p class="meta">' + blurb + '</p>';
        h += '<p>Events: <strong>' + (count || 0) + '</strong> · unique properties: <strong>' + (propCount || 0) + '</strong></p>';
        if (sample) h += '<p class="meta mono">' + escapeHtml(sample) + '</p>';
        if (codes && codes.length) {
          h += '<h3>Error codes</h3><table class="data"><thead><tr><th>Code</th><th>Count</th></tr></thead><tbody>';
          codes.forEach(function (r) {
            h += '<tr><td class="mono">' + escapeHtml(String(r.code)) + '</td><td>' + r.count + '</td></tr>';
          });
          h += '</tbody></table>';
        }
        if (props && props.length) {
          h += '<h3>Top properties</h3><table class="data"><thead><tr><th>Property</th><th>Count</th></tr></thead><tbody>';
          props.forEach(function (r) {
            h += '<tr><td class="mono">' + escapeHtml(r.property) + '</td><td>' + r.count + '</td></tr>';
          });
          h += '</tbody></table>';
        }
        return h;
      }

      if ((b.collectTrend || 0) > 0 || (b.timeSync || 0) > 0) {
        html += cmdBlock(
          'BACnetCollectTrend',
          'Driver command failures when collecting trends (often Log_Enable). Usually logged under CoHo/GmsOrchBatchCmd, not WCCOAGmsBACnet.',
          b.collectTrend, b.collectTrendProps, b.collectTrendSample, b.collectTrendCodes, b.collectTrendTop
        );
        html += cmdBlock(
          'BACnetTimeSync',
          'Driver command failures when pushing device time sync (often Local_Time). Same CoHo/orchestration path as CollectTrend.',
          b.timeSync, b.timeSyncProps, b.timeSyncSample, b.timeSyncCodes, b.timeSyncTop
        );
      }
    }
    html += renderLifecycleHtml(b.lifecycle);
    el.innerHTML = html || '<p class="meta">No BACnet signals in the current window.</p>';
  }

  function renderCns(c) {
    var el = $('cnsBody');
    var hasSig = c && ((c.resolveNodes || 0) + (c.reducedFunction || 0) + (c.tryRenew || 0) > 0);
    var hasLife = c && lifecycleHasSignal(c.lifecycle);
    if (!hasSig && !hasLife) {
      el.innerHTML = '<p class="meta">No CNS signals in the current window.</p>';
      return;
    }
    el.innerHTML = '';
    if (hasSig) {
      var p = document.createElement('p');
      p.innerHTML = 'ResolveNodes: <strong>' + c.resolveNodes + '</strong> · ReducedFunction: <strong>' +
        c.reducedFunction + '</strong> · ICns: <strong>' + (c.icns || 0) + '</strong> · TryRenewSession: <strong>' +
        c.tryRenew + '</strong>';
      el.appendChild(p);
      renderPatternListInto(el, { SEVERE: c.patterns || [] });
    }
    var lifeWrap = document.createElement('div');
    lifeWrap.innerHTML = renderLifecycleHtml(c.lifecycle);
    if (lifeWrap.innerHTML) el.appendChild(lifeWrap);
  }

  function renderCoho(c) {
    var el = $('cohoBody');
    var hasSig = c && (c.stuck > 0);
    var hasLife = c && lifecycleHasSignal(c.lifecycle);
    if (!hasSig && !hasLife) {
      el.innerHTML = '<p class="meta">No CoHo stuck/drop or manager-health signals in the current window.</p>';
      return;
    }
    var html = '';
    if (hasSig) {
      html += '<p>Stuck/drop: <strong>' + c.stuck + '</strong></p>';
      if (c.sample) html += '<p class="meta mono">' + escapeHtml(c.sample) + '</p>';
      html += '<table class="data"><thead><tr><th>Count</th><th>Name</th></tr></thead><tbody>';
      (c.topNames || []).forEach(function (r) {
        html += '<tr><td>' + r.count + '</td><td class="mono">' + escapeHtml(r.name) + '</td></tr>';
      });
      html += '</tbody></table>';
    }
    html += renderLifecycleHtml(c.lifecycle, {
      blockingSample: c.blockingSample,
      unblockingSample: c.unblockingSample
    });
    el.innerHTML = html;
  }

  function renderApogee(a) {
    var el = $('apogeeBody');
    var drvHits = a ? ((a.drvLines || 0) + (a.trendOverflow || 0) + (a.trendSeq || 0) +
      (a.alertId || 0) + (a.queryTimeout || 0) + (a.getDataFail || 0)) : 0;
    var hasSig = a && ((a.events > 0) || (drvHits > 0));
    var hasLife = a && lifecycleHasSignal(a.lifecycle);
    if (!hasSig && !hasLife) {
      el.innerHTML = '<p class="meta">No Apogee signals in the current window.</p>';
      return;
    }
    var html = '';
    if (hasSig) {
      html += '<p>CoHo/Orch events: <strong>' + (a.events || 0) + '</strong> · UpdatePoints: <strong>' +
        (a.updatePoints || 0) + '</strong> · Repetition: <strong>' + (a.repetition || 0) +
        '</strong> · Other: <strong>' + (a.other || 0) +
        '</strong> · unique PPCL: <strong>' + (a.uniquePpcl || 0) + '</strong></p>';
      if (a.sample) html += '<p class="meta mono">' + escapeHtml(a.sample) + '</p>';
      html += '<h2>UpdatePoints / PPCL (CoHo.Apogee* / Orch.Apogee*)</h2>';
      html += '<p class="meta">Orchestration / ApogeeBACnet path — not WCCOAApogeeDrv.</p>';
      html += '<table class="data"><thead><tr><th>Count</th><th>PPCL</th></tr></thead><tbody>';
      (a.topPpcl || []).forEach(function (r) {
        html += '<tr><td>' + r.count + '</td><td class="mono">' + escapeHtml(r.name) + '</td></tr>';
      });
      html += '</tbody></table>';

      if (drvHits > 0) {
        html += '<h2>WCCOAApogeeDrv</h2>';
        html += '<p class="meta">Native Apogee driver lines (trend collection, alerts, queries).</p>';
        html += '<p>Driver lines: <strong>' + (a.drvLines || 0) +
          '</strong> · trend overflow: <strong>' + (a.trendOverflow || 0) +
          '</strong> · sequence gaps: <strong>' + (a.trendSeq || 0) +
          '</strong> · AlertID: <strong>' + (a.alertId || 0) +
          '</strong> · query timeout: <strong>' + (a.queryTimeout || 0) +
          '</strong> · get-data fail: <strong>' + (a.getDataFail || 0) + '</strong></p>';

        html += '<h3>Trend buffer overflow</h3>';
        html += '<p class="meta">Missed trend samples on the panel; “Last sequence number…” lines are the companion sequence-gap warnings.</p>';
        html += '<p>Overflows: <strong>' + (a.trendOverflow || 0) +
          '</strong> · sequence-gap lines: <strong>' + (a.trendSeq || 0) +
          '</strong> · unique devices: <strong>' + (a.trendDevices || 0) +
          '</strong> · unique trends: <strong>' + (a.trendNames || 0) + '</strong></p>';
        if (a.trendSample) html += '<p class="meta mono">' + escapeHtml(a.trendSample) + '</p>';
        if ((a.topTrendDevices || []).length) {
          html += '<table class="data"><thead><tr><th>Device</th><th>Count</th></tr></thead><tbody>';
          a.topTrendDevices.forEach(function (r) {
            html += '<tr><td class="mono">' + escapeHtml(r.device) + '</td><td>' + r.count + '</td></tr>';
          });
          html += '</tbody></table>';
        }
        if ((a.topTrends || []).length) {
          html += '<h3>Top trends</h3><table class="data"><thead><tr><th>Trend</th><th>Count</th></tr></thead><tbody>';
          a.topTrends.forEach(function (r) {
            html += '<tr><td class="mono">' + escapeHtml(r.trend) + '</td><td>' + r.count + '</td></tr>';
          });
          html += '</tbody></table>';
        }

        html += '<h3>AlertID</h3>';
        html += '<p class="meta">Unknown / out-of-order alert handling (sendAck, sendGoneAlert, etc.).</p>';
        html += '<p>Events: <strong>' + (a.alertId || 0) + '</strong></p>';
        if (a.alertSample) html += '<p class="meta mono">' + escapeHtml(a.alertSample) + '</p>';

        html += '<h3>Query timeout</h3>';
        html += '<p class="meta">RequestHandler pending-answer timeouts.</p>';
        html += '<p>Events: <strong>' + (a.queryTimeout || 0) + '</strong></p>';
        if (a.timeoutSample) html += '<p class="meta mono">' + escapeHtml(a.timeoutSample) + '</p>';

        html += '<h3>Failed to get data</h3>';
        html += '<p class="meta">Object read failures (often network timeout) on ApogeeDrv.</p>';
        html += '<p>Events: <strong>' + (a.getDataFail || 0) +
          '</strong> · unique devices: <strong>' + (a.getDataDevices || 0) + '</strong></p>';
        if (a.getDataSample) html += '<p class="meta mono">' + escapeHtml(a.getDataSample) + '</p>';
        if ((a.topGetDataDevices || []).length) {
          html += '<table class="data"><thead><tr><th>Device</th><th>Count</th></tr></thead><tbody>';
          a.topGetDataDevices.forEach(function (r) {
            html += '<tr><td class="mono">' + escapeHtml(r.device) + '</td><td>' + r.count + '</td></tr>';
          });
          html += '</tbody></table>';
        }
      }
    }
    html += renderLifecycleHtml(a.lifecycle);
    el.innerHTML = html;
  }

  function renderMore(m) {
    var el = $('moreBody');
    var html = '<h2>Performance categories</h2>';
    if (!m || !(m.perfCategories || []).length) html += '<p class="meta">None</p>';
    else {
      html += '<table class="data"><thead><tr><th>Count</th><th>Category</th></tr></thead><tbody>';
      m.perfCategories.forEach(function (r) {
        html += '<tr><td>' + r.count + '</td><td>' + escapeHtml(r.name) + '</td></tr>';
      });
      html += '</tbody></table>';
    }
    html += '<h2>Parse notes</h2><p class="meta">Parsed header lines: ' +
      Number((m && m.parsedLines) || 0).toLocaleString() +
      ' · Skipped / unparsed: ' + Number((m && m.unparsedLines) || 0).toLocaleString() + '</p>';
    if (m && m.health) {
      html += '<h2>Health</h2><p class="meta mono">' + escapeHtml(JSON.stringify(m.health)) + '</p>';
    }
    el.innerHTML = html;
  }

  // Mirror of Format-DurationLabel in Watch-PvssLog.ps1 - the dashboard and the report must
  // describe the same span the same way.
  function durationLabel(sec) {
    var s = Math.round(Number(sec) || 0);
    if (s < 0) return '';
    if (s < 60) return s + 's';
    var m = Math.floor(s / 60), r = s % 60;
    if (m < 60) return r === 0 ? (m + 'm') : (m + 'm ' + r + 's');
    var h = Math.floor(m / 60), m2 = m % 60;
    if (h < 48) return m2 === 0 ? (h + 'h') : (h + 'h ' + m2 + 'm');
    var d = Math.floor(h / 24), h2 = h % 24;
    return h2 === 0 ? (d + 'd') : (d + 'd ' + h2 + 'h');
  }

  // "18x threshold" - volume against the rule's own FindingAt bar. Shown instead of the rate
  // that drives the ordering, because a seven-second burst rates at 270,000/hr.
  function ruleBadge(r) {
    var at = Number(r.findingAt) || 0;
    if (at <= 0) return '';
    var o = Number(r.over) || 0;
    var n = o >= 10 ? Math.round(o).toLocaleString() : o.toFixed(1);
    return ' <span class="badge' + (o >= 1 ? ' over' : '') +
      '" title="Raises a finding at ' + at.toLocaleString() + ' line(s)">' + n + '\u00d7 threshold</span>';
  }

  // Generic: walks whatever the rule table produced. Adding a rule needs no edit here.
  function renderDetections(groups) {
    var el = $('detectionsBody');
    groups = groups || [];
    if (!groups.length) {
      el.innerHTML = '<p class="meta">No rule detections in the current window.</p>';
      return;
    }
    var html = '';
    groups.forEach(function (g) {
      html += '<h2>' + escapeHtml(g.group) + ' <span class="meta">(' +
        Number(g.total || 0).toLocaleString() + ' lines)</span></h2>';
      (g.rules || []).forEach(function (r) {
        html += '<h3>' + escapeHtml(r.label) + ruleBadge(r) + '</h3>';
        // One severity covering every line just restates the count, so name it in the
        // headline ("161,964 SEVERE line(s)") rather than echoing the number twice.
        var sk = Object.keys(r.severities || {});
        var sevWord = '', sevTxt = '';
        if (sk.length === 1 && Number(r.severities[sk[0]]) === Number(r.count)) {
          sevWord = escapeHtml(sk[0]) + ' ';
        } else if (sk.length) {
          sevTxt = ' · ' + sk.map(function (k) {
            return escapeHtml(k) + ' ' + Number(r.severities[k]).toLocaleString();
          }).join(', ');
        }
        // Where a rule carries a Measure the aggregate is the story, not the line count.
        var mk = Object.keys(r.measures || {});
        var head = '';
        if (mk.length) {
          head = mk.map(function (k) {
            return escapeHtml(k) + ': <strong>' + Number(r.measures[k]).toLocaleString() + '</strong>';
          }).join(' · ') + ' · over ' + Number(r.count || 0).toLocaleString() + ' ' + sevWord + 'line(s)';
        } else {
          head = '<strong>' + Number(r.count || 0).toLocaleString() + '</strong> ' + sevWord + 'line(s)';
        }
        html += '<p>' + head + sevTxt + '</p>';
        if (r.first) {
          // Duration is what makes the ordering legible: 4,563 hits over 4h is an outage,
          // the same count over three weeks is background.
          html += '<p class="meta">' + escapeHtml(r.first) + ' → ' + escapeHtml(r.last) +
            ' · ' + escapeHtml(durationLabel(r.spanSec)) +
            ' · rule <span class="mono">' + escapeHtml(r.id) + '</span></p>';
        }
        if (r.sample) html += '<p class="meta mono">' + escapeHtml(r.sample) + '</p>';
        Object.keys(r.buckets || {}).forEach(function (bn) {
          var b = r.buckets[bn];
          var rows = (b && b.top) || [];
          if (!rows.length) return;
          // A single distinct value does not need a table around it - say it in words.
          if (Number(b.distinct) === 1 && rows.length === 1) {
            html += '<p class="meta">All from ' + escapeHtml(bn) +
              ' <span class="mono">' + escapeHtml(rows[0].value) + '</span></p>';
            return;
          }
          html += '<p class="meta">By ' + escapeHtml(bn) + ' — ' +
            Number(b.distinct || 0).toLocaleString() + ' distinct' + (b.capped ? ' (capped)' : '') + '</p>';
          html += '<table class="data kv"><thead><tr><th>Count</th><th>' + escapeHtml(bn) +
            '</th></tr></thead><tbody>';
          rows.forEach(function (x) {
            html += '<tr><td>' + Number(x.count).toLocaleString() + '</td><td class="mono">' +
              escapeHtml(x.value) + '</td></tr>';
          });
          html += '</tbody></table>';
        });
      });
    });
    el.innerHTML = html;
  }

  function loadSection(name) {
    var q = qsPulse() + '&name=' + encodeURIComponent(name === 'more' ? 'perf' : name);
    return apiGet('/api/section?' + q).then(function (res) {
      if (res.status === 304) return;
      var j = res.json;
      state.sectionGeneration[name] = j.generation;
      if (name === 'patterns') renderPatternList(j.patternsBySeverity);
      if (name === 'managers') renderManagersTable(j.managers);
      if (name === 'bacnet') renderBacnet(j.bacnet);
      if (name === 'cns') renderCns(j.cns);
      if (name === 'coho') renderCoho(j.coho);
      if (name === 'apogee') renderApogee(j.apogee);
      if (name === 'detections') renderDetections(j.detections);
      if (name === 'more') renderMore(j);
    }).catch(function (e) {
      setBanner('bannerError', String(e.message || e));
    });
  }

  function loadManagerDetail(name) {
    var q = qsPulse() + '&name=' + encodeURIComponent(name);
    return apiGet('/api/manager?' + q).then(function (res) {
      if (res.status === 304) return;
      renderManagerDetail(res.json);
    }).catch(function (e) {
      setBanner('bannerError', String(e.message || e));
    });
  }

  function pollPulse(opts) {
    opts = opts || {};
    var force = !!opts.force;
    var headersNote = '';
    var url = '/api/pulse?' + qsPulse();
    // sinceGeneration must be skipped when filters change — generation is unchanged but series/sections must refresh.
    if (!force && state.generation != null && !state.useMock) {
      url += '&sinceGeneration=' + encodeURIComponent(state.generation);
    }
    return apiGet(url).then(function (res) {
      if (res.status === 304) {
        if (state.lastPulseAt) {
          var sec = Math.round((Date.now() - state.lastPulseAt) / 1000);
          var mode = state.windowEntire ? 'Entire file' : (state.lastMinutes + 'm');
          setStatus('<span class="ok">tailing</span> · window ' + mode + ' · gen ' + state.generation +
            ' · updated ' + sec + 's ago' + headersNote);
        }
        // Never leave a client-only loading banner stuck after a no-op 304.
        if (!state.pulse || !state.pulse.loading) setBanner('bannerLoading', '');
        return;
      }
      var prev = state.generation;
      applyPulse(res.json);
      if (force || (state.activeView !== 'overview' && res.json.generation !== prev)) {
        if (state.activeView !== 'overview') {
          loadSection(state.activeView);
          if (state.activeView === 'managers' && state.selectedManager) {
            loadManagerDetail(state.selectedManager);
          }
        }
      }
    }).catch(function (e) {
      setBanner('bannerLoading', '');
      setBanner('bannerError', String(e.message || e));
      setStatus('<span class="err">poll failed</span>');
    });
  }

  function desiredPollMs() {
    // Fast while Start / window catch-up is in progress; otherwise RefreshSeconds.
    if (state.starting || state.awaitingLoad || (state.pulse && state.pulse.loading)) {
      return Math.max(250, Math.min(2000, state.loadingPollMs || 500));
    }
    return Math.max(1000, Math.min(60000, (state.refreshSeconds || 3) * 1000));
  }

  function stopPollingTimer() {
    if (state.pollTimer) {
      clearTimeout(state.pollTimer);
      state.pollTimer = null;
    }
  }

  function runPollCycle() {
    if (!state.polling) return;
    stopPollingTimer();
    var done = function () {
      if (!state.polling) return;
      state.pollTimer = setTimeout(runPollCycle, desiredPollMs());
    };
    var p = pollPulse();
    if (p && typeof p.then === 'function') p.then(done, done);
    else done();
  }

  function startPolling() {
    state.polling = true;
    stopPollingTimer();
    runPollCycle();
  }

  function stopPolling() {
    state.polling = false;
    stopPollingTimer();
  }

  function nudgePolling() {
    if (!state.polling) return;
    stopPollingTimer();
    runPollCycle();
  }

  function showView(name) {
    state.activeView = name;
    document.querySelectorAll('#nav button').forEach(function (b) {
      b.classList.toggle('active', b.getAttribute('data-view') === name);
    });
    document.querySelectorAll('main .view').forEach(function (v) {
      v.classList.toggle('active', v.id === 'view-' + name);
    });
    if (state.running || state.useMock) {
      if (name !== 'overview') loadSection(name);
    }
  }

  function syncWindowButtons() {
    document.querySelectorAll('#windowPresets .chip').forEach(function (b) {
      var entire = b.getAttribute('data-entire') === '1';
      var mins = parseInt(b.getAttribute('data-minutes') || '0', 10);
      var on = state.windowEntire ? entire : (!entire && mins === state.lastMinutes);
      b.classList.toggle('active', on);
      b.setAttribute('aria-pressed', on ? 'true' : 'false');
    });
  }

  function showLoading(msg) {
    state.awaitingLoad = true;
    state.sawLoading = false;
    state.loadRequestDone = false;
    setBanner('bannerLoading', msg || 'Loading window…');
    setStatus('<span class="warn">loading</span> · waiting for host…');
    // Lock now rather than waiting up to a poll interval for the next pulse to do it.
    updateChromeButtons();
  }

  function requestWindowChange() {
    syncWindowButtons();
    if (!state.running && !state.useMock) {
      return;
    }
    // Show loading immediately — do not wait for the host (catch-up can take many seconds).
    showLoading(state.windowEntire ? 'Loading entire file… 0%' : ('Loading last ' + state.lastMinutes + ' minutes… 0%'));
    if (state.useMock) {
      nudgePolling();
      pollPulse();
      return;
    }
    apiPost('/api/control', {
      action: 'setWindow',
      window: state.windowEntire ? 'entire' : 'minutes',
      lastMinutes: state.lastMinutes
    }).then(function () {
      state.loadRequestDone = true;
      nudgePolling();
    }).catch(function (e) {
      state.awaitingLoad = false;
      state.sawLoading = false;
      state.loadRequestDone = false;
      setBanner('bannerLoading', '');
      setBanner('bannerError', String(e.message || e));
    });
  }

  function bindUi() {
    document.querySelectorAll('#nav button').forEach(function (b) {
      b.addEventListener('click', function () { showView(b.getAttribute('data-view')); });
    });

    $('btnToggleMgrList').addEventListener('click', function () {
      setMgrListCollapsed(!state.mgrListCollapsed);
    });

    document.querySelectorAll('#sevChips .chip').forEach(function (b) {
      b.addEventListener('click', function () {
        var s = b.getAttribute('data-sev');
        state.severities[s] = !state.severities[s];
        b.classList.toggle('active', state.severities[s]);
        b.setAttribute('aria-pressed', state.severities[s] ? 'true' : 'false');
        if (state.running || state.useMock) {
          // Filters are query-side only (no catch-up). Force a full pulse so charts refresh;
          // do not use the catch-up loading banner (it stuck on HTTP 304 before).
          var sevLabel = selectedSeverities().join(',') || '(none)';
          setStatus('<span class="warn">applying filters</span> · ' + escapeHtml(sevLabel));
          if (!state.useMock) {
            apiPost('/api/control', { action: 'note', message: 'Severity filter → ' + sevLabel }).catch(function () { });
          }
          pollPulse({ force: true });
          if (state.activeView !== 'overview') loadSection(state.activeView);
        }
      });
    });

    document.querySelectorAll('#areaChips .chip').forEach(function (b) {
      b.addEventListener('click', function () {
        var a = b.getAttribute('data-area');
        state.areas[a] = !state.areas[a];
        b.classList.toggle('active', state.areas[a]);
        b.setAttribute('aria-pressed', state.areas[a] ? 'true' : 'false');
        if (state.running || state.useMock) {
          var areaLabel = selectedAreas().join(',') || '(none)';
          setStatus('<span class="warn">applying filters</span> · areas ' + escapeHtml(areaLabel));
          if (!state.useMock) {
            apiPost('/api/control', { action: 'note', message: 'Area filter → ' + areaLabel }).catch(function () { });
          }
          pollPulse({ force: true });
          if (state.activeView !== 'overview') loadSection(state.activeView);
        }
      });
    });

    document.querySelectorAll('#windowPresets .chip').forEach(function (b) {
      b.addEventListener('click', function () {
        // Must bail before touching state: the chips reflect state.windowEntire /
        // state.lastMinutes, so mutating and then refusing to send is the desync itself.
        if (windowLocked()) return;
        if (b.getAttribute('data-entire') === '1') {
          state.windowEntire = true;
        } else {
          state.windowEntire = false;
          state.lastMinutes = parseInt(b.getAttribute('data-minutes'), 10);
          $('customWindowValue').value = '';
        }
        requestWindowChange();
      });
    });

    function getCustomWindowUnit() {
      var on = document.querySelector('#customWindowUnit .unit-chip.active');
      return on ? on.getAttribute('data-unit') : 'minutes';
    }

    function syncCustomWindowLimits() {
      var unit = getCustomWindowUnit();
      var inp = $('customWindowValue');
      if (unit === 'hours') {
        inp.min = '1';
        inp.max = '168'; // 7 days in hours (matches 10080 minutes)
        inp.placeholder = '2';
      } else {
        inp.min = '1';
        inp.max = '10080';
        inp.placeholder = '60';
      }
    }

    function applyCustomWindow() {
      if (windowLocked()) return;
      var n = parseInt($('customWindowValue').value, 10);
      if (!n || n < 1) return;
      var unit = getCustomWindowUnit();
      var minutes = unit === 'hours' ? n * 60 : n;
      if (minutes < 1) return;
      state.windowEntire = false;
      state.lastMinutes = Math.min(10080, minutes);
      requestWindowChange();
    }

    document.querySelectorAll('#customWindowUnit .unit-chip').forEach(function (b) {
      b.addEventListener('click', function () {
        document.querySelectorAll('#customWindowUnit .unit-chip').forEach(function (x) {
          var on = x === b;
          x.classList.toggle('active', on);
          x.setAttribute('aria-pressed', on ? 'true' : 'false');
        });
        syncCustomWindowLimits();
      });
    });
    syncCustomWindowLimits();

    $('btnApplyWindow').addEventListener('click', applyCustomWindow);
    $('customWindowValue').addEventListener('keydown', function (e) {
      if (e.key === 'Enter') applyCustomWindow();
    });

    $('btnStart').addEventListener('click', function () {
      var path = $('logPath').value.trim();
      if (state.useMock) {
        state.running = true;
        applyPulse(mockPulse());
        startPolling();
        return;
      }
      if (!path) {
        setBanner('bannerError', 'Enter a log path before Start.');
        return;
      }
      if (state.starting) return;
      state.starting = true;
      setBanner('bannerError', '');
      showLoading(state.windowEntire
        ? 'Loading entire file… 0%'
        : ('Loading last ' + state.lastMinutes + ' minutes… 0%'));
      $('btnStart').disabled = true;
      var body = {
        path: path,
        window: state.windowEntire ? 'entire' : 'minutes',
        lastMinutes: state.lastMinutes
      };
      // Poll fast while Start/catch-up is in flight (awaitingLoad until pulse.loading clears).
      startPolling();
      apiPost('/api/logPath', body).then(function () {
        state.running = true;
        state.starting = false;
        state.loadRequestDone = true;
        updateChromeButtons();
        nudgePolling();
      }).catch(function (e) {
        state.starting = false;
        state.awaitingLoad = false;
        state.sawLoading = false;
        state.loadRequestDone = false;
        state.running = false;
        stopPolling();
        setBanner('bannerLoading', '');
        setBanner('bannerError', String(e.message || e));
        updateChromeButtons();
      });
    });

    $('btnPause').addEventListener('click', function () {
      apiPost('/api/control', { action: 'pause' }).then(pollPulse);
    });
    $('btnResume').addEventListener('click', function () {
      apiPost('/api/control', { action: 'resume' }).then(pollPulse);
    });
    $('btnSnapshot').addEventListener('click', openSnapFormats);
    $('snapFormats').addEventListener('click', function (ev) {
      var btn = ev.target.closest ? ev.target.closest('.chip') : null;
      if (!btn) return;
      closeSnapFormats();
      downloadSnapshot(btn.getAttribute('data-format'));
    });
    document.addEventListener('keydown', function (ev) {
      if (ev.key === 'Escape' && !$('snapFormats').hidden) closeSnapFormats();
    });
    document.addEventListener('click', function (ev) {
      if ($('snapFormats').hidden) return;
      if (ev.target.closest && ev.target.closest('.snap-slot')) return;
      closeSnapFormats();
    });
    $('btnRestart').addEventListener('click', function () {
      stopPolling();
      state.starting = false;
      state.awaitingLoad = false;
      state.sawLoading = false;
      state.loadRequestDone = false;
      apiPost('/api/control', { action: 'restart' }).then(function () {
        state.running = false;
        state.paused = false;
        state.pulse = null;
        state.generation = null;
        state.selectedManager = null;
        state.mgrListCollapsed = false;
        state.managersCache = null;
        $('mgrDetail').hidden = true;
        $('mgrDetailBody').innerHTML = '';
        updateMgrListCollapseUi();
        $('overviewBody').hidden = true;
        $('idleHint').hidden = false;
        setBanner('bannerLoading', '');
        setBanner('bannerRotate', '');
        setBanner('bannerError', '');
        setStatus('Idle — enter path and Start');
        updateChromeButtons();
        $('logPath').readOnly = false;
        refreshReloadedConfig();
      }).catch(function (e) {
        setBanner('bannerError', String(e.message || e));
      });
    });
  }

  // Restart makes the host re-read watch-config.txt. Pick up the values that are
  // visible from here; severity/area chips and the window keep the current
  // selection and only re-seed from the file on a page reload.
  function refreshReloadedConfig() {
    if (state.useMock) return;
    apiGet('/api/health').then(function (res) {
      var h = res.json || {};
      var rs = parseInt(h.refreshSeconds, 10);
      if (rs >= 1 && rs <= 60) state.refreshSeconds = rs;
      $('logPath').value = h.prefillPath || '';
    }).catch(function () { });
  }

  function applyHealthDefaults(h) {
    if (!h) return;
    if (h.refreshSeconds) {
      var rs = parseInt(h.refreshSeconds, 10);
      if (rs >= 1 && rs <= 60) state.refreshSeconds = rs;
    }
    var d = h.defaults || {};
    if (typeof d.windowEntire === 'boolean') {
      state.windowEntire = d.windowEntire;
    }
    if (d.lastMinutes) {
      var lm = parseInt(d.lastMinutes, 10);
      if (lm >= 1) state.lastMinutes = lm;
    }
    if (d.severities && d.severities.length) {
      SEVS.forEach(function (s) { state.severities[s] = false; });
      d.severities.forEach(function (s) {
        var u = String(s).toUpperCase();
        if (state.severities.hasOwnProperty(u)) state.severities[u] = true;
      });
      document.querySelectorAll('#sevChips .chip-sev').forEach(function (b) {
        var s = b.getAttribute('data-sev');
        var on = !!state.severities[s];
        b.classList.toggle('active', on);
        b.setAttribute('aria-pressed', on ? 'true' : 'false');
      });
    }
    if (d.areas && d.areas.length) {
      AREAS.forEach(function (a) { state.areas[a] = false; });
      d.areas.forEach(function (a) {
        var u = String(a).toUpperCase();
        if (state.areas.hasOwnProperty(u)) state.areas[u] = true;
      });
      document.querySelectorAll('#areaChips .chip-area').forEach(function (b) {
        var a = b.getAttribute('data-area');
        var on = !!state.areas[a];
        b.classList.toggle('active', on);
        b.setAttribute('aria-pressed', on ? 'true' : 'false');
      });
    }
    syncWindowButtons();
  }

  function boot() {
    bindUi();
    syncWindowButtons();
    updateChromeButtons();
    if (state.useMock) {
      setStatus('Mock mode — press Start to load sample dashboard');
      applyHealthDefaults({
        refreshSeconds: 3,
        defaults: { lastMinutes: 60, windowEntire: false, severities: ['FATAL', 'SEVERE', 'ERROR', 'WARNING'] }
      });
      return;
    }
    apiGet('/api/health').then(function (res) {
      var h = res.json || {};
      applyHealthDefaults(h);
      if (h.prefillPath) $('logPath').value = h.prefillPath;
      var verEl = $('appVersion');
      if (verEl && (h.version || h.author)) {
        verEl.hidden = false;
        verEl.textContent = 'v' + (h.version || '') + (h.author ? (' · ' + h.author) : '');
      }
      if (h.listeningUrl) setStatus('Idle — host ' + escapeHtml(h.listeningUrl));
    }).catch(function () {
      setStatus('Idle — host not reachable (open via Run-Watch.cmd)');
    });
  }

  boot();
})();
