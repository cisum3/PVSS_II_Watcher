/* PVSS Log Watch UI — pulse/section/manager client (PRD-V2) */
(function () {
  'use strict';

  var SEVS = ['FATAL', 'SEVERE', 'ERROR', 'WARNING', 'INFO'];
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
    severities: { FATAL: true, SEVERE: true, ERROR: true, WARNING: true, INFO: false },
    generation: null,
    sectionGeneration: {},
    selectedManager: null,
    activeView: 'overview',
    pulse: null,
    pollTimer: null,
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
    return p.toString();
  }

  function mockPulse() {
    return {
      generation: 1,
      window: { mode: 'minutes', lastMinutes: 60 },
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
        'CNS volume: ResolveNodes=140, ReducedFunction=12, ICns=4.'
      ],
      severityCounts: { FATAL: 2, SEVERE: 180, ERROR: 40, WARNING: 920, INFO: 12000 },
      moduleHeadlines: {
        bacnet: { failed: 1200, ok: 980, endedFailed: 42, objectList: 15 },
        cns: { resolveNodes: 140, reducedFunction: 12, tryRenew: 3 },
        coho: { stuck: 8 },
        apogee: { events: 22, updatePoints: 11 }
      },
      topManagers: [
        { name: 'WCCOAGmsBACnet', count: 8500 },
        { name: 'WCCOAGmsCoHoMngr', count: 2100 },
        { name: 'Siemens.Gms.ApplicationFramework', count: 900 },
        { name: 'Site.CustomDriver', count: 400 }
      ],
      series: {
        byMinute: [
          { t: '2026.09.05 15:00', FATAL: 0, SEVERE: 2, ERROR: 1, WARNING: 10, INFO: 80, bacFailed: 5, bacOk: 4 },
          { t: '2026.09.05 15:01', FATAL: 0, SEVERE: 4, ERROR: 0, WARNING: 12, INFO: 90, bacFailed: 8, bacOk: 6 },
          { t: '2026.09.05 15:02', FATAL: 1, SEVERE: 3, ERROR: 2, WARNING: 8, INFO: 70, bacFailed: 3, bacOk: 7 }
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
          topPpcl: [{ name: 'PROG_A', count: 6 }, { name: 'PROG_B', count: 3 }]
        }
      };
    }
    if (name === 'perf') {
      return {
        generation: 1,
        perfCategories: [{ name: 'Timeout', count: 6 }, { name: 'CNS/Resolve', count: 140 }],
        unparsedLines: 120,
        parsedLines: 50000,
        health: { version: '2.0-dev', port: 8787 }
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
          return { status: 200, json: { ok: true, version: '2.0-dev', mock: true, prefillPath: '' } };
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

  function updateChromeButtons() {
    $('btnStart').disabled = state.running || state.starting;
    $('btnPause').disabled = !state.running || state.paused || state.starting;
    $('btnResume').disabled = !state.running || !state.paused || state.starting;
    $('btnRestart').disabled = (!state.running && !state.pulse && !state.starting);
    $('logPath').readOnly = (state.running || state.starting) && !state.useMock;
  }

  function setStatus(html) {
    $('statusLine').innerHTML = html;
  }

  function selectedSeverities() {
    return SEVS.filter(function (s) { return state.severities[s]; });
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

  function updateCharts(series) {
    ensureCharts();
    var rows = (series && series.byMinute) || [];
    var sevList = selectedSeverities().filter(function (s) { return s !== 'INFO' || state.severities.INFO; });
    var labels = rows.map(function (r) { return (r.t || '').slice(11, 16) || r.t; });
    var hasVol = rows.some(function (r) {
      return sevList.some(function (s) { return (r[s] || 0) > 0; });
    });
    $('chartVolumeEmpty').hidden = hasVol;
    if (typeof Chart !== 'undefined') {
      var datasets = sevList.map(function (s) {
        return {
          label: s,
          data: rows.map(function (r) { return r[s] || 0; }),
          backgroundColor: SEV_COLORS[s],
          stack: 's'
        };
      });
      if (!state.chartVolume) {
        state.chartVolume = new Chart($('chartVolume'), {
          type: 'bar',
          data: { labels: labels, datasets: datasets },
          options: {
            responsive: true,
            maintainAspectRatio: false,
            plugins: { legend: { position: 'bottom', labels: { boxWidth: 10 } } },
            scales: { x: { stacked: true }, y: { stacked: true, beginAtZero: true } }
          }
        });
      } else {
        state.chartVolume.data.labels = labels;
        state.chartVolume.data.datasets = datasets;
        state.chartVolume.update('none');
      }
    }

    var hasBac = rows.some(function (r) { return (r.bacFailed || 0) + (r.bacOk || 0) > 0; });
    var hasSevFallback = !hasBac && rows.some(function (r) { return (r.SEVERE || 0) > 0; });
    $('chartBacnetEmpty').hidden = hasBac || hasSevFallback;
    if (typeof Chart !== 'undefined') {
      var ds2;
      if (hasBac) {
        ds2 = [
          { label: 'Failed', data: rows.map(function (r) { return r.bacFailed || 0; }), borderColor: SEV_COLORS.SEVERE, backgroundColor: 'transparent', tension: 0.2 },
          { label: 'OK', data: rows.map(function (r) { return r.bacOk || 0; }), borderColor: SEV_COLORS.INFO, backgroundColor: 'transparent', tension: 0.2 }
        ];
      } else {
        ds2 = [
          { label: 'SEVERE', data: rows.map(function (r) { return r.SEVERE || 0; }), borderColor: SEV_COLORS.SEVERE, backgroundColor: 'transparent', tension: 0.2 }
        ];
      }
      if (!state.chartBacnet) {
        state.chartBacnet = new Chart($('chartBacnet'), {
          type: 'line',
          data: { labels: labels, datasets: ds2 },
          options: {
            responsive: true,
            maintainAspectRatio: false,
            plugins: { legend: { position: 'bottom', labels: { boxWidth: 10 } } },
            scales: { y: { beginAtZero: true } }
          }
        });
      } else {
        state.chartBacnet.data.labels = labels;
        state.chartBacnet.data.datasets = ds2;
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

    renderFindings(p.findings);
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
    ['FATAL', 'SEVERE', 'ERROR', 'WARNING'].forEach(function (sev) {
      var block = document.createElement('div');
      block.className = 'pattern-block';
      var list = (bySev && bySev[sev]) || [];
      block.innerHTML = '<h3 style="color:' + SEV_COLORS[sev] + '">' + sev +
        '<span class="meta">(' + list.length + ')</span></h3>';
      if (!list.length) {
        block.innerHTML += '<p class="meta">No patterns</p>';
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
    renderPatternListInto(body, data.patternsBySeverity);
    updateMgrListCollapseUi();
    if (state.mgrListCollapsed) {
      try { $('mgrDetail').scrollIntoView({ behavior: 'smooth', block: 'start' }); } catch (e) { $('mgrDetail').scrollIntoView(true); }
    }
  }

  function renderPatternListInto(host, bySev) {
    var wrap = document.createElement('div');
    ['FATAL', 'SEVERE', 'ERROR', 'WARNING'].forEach(function (sev) {
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
    host.appendChild(wrap);
  }

  function renderBacnet(b) {
    var el = $('bacnetBody');
    if (!b || ((b.failed || 0) + (b.ok || 0) + (b.objectList || 0) === 0)) {
      el.innerHTML = '<p class="meta">No BACnet signals in the current window.</p>';
      return;
    }
    var html = '<p>Failed transitions: <strong>' + b.failed + '</strong> · OK: <strong>' + b.ok +
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
    el.innerHTML = html;
  }

  function renderCns(c) {
    var el = $('cnsBody');
    if (!c || ((c.resolveNodes || 0) + (c.reducedFunction || 0) + (c.tryRenew || 0) === 0)) {
      el.innerHTML = '<p class="meta">No CNS signals in the current window.</p>';
      return;
    }
    el.innerHTML = '<p>ResolveNodes: <strong>' + c.resolveNodes + '</strong> · ReducedFunction: <strong>' +
      c.reducedFunction + '</strong> · ICns: <strong>' + (c.icns || 0) + '</strong> · TryRenewSession: <strong>' +
      c.tryRenew + '</strong></p>';
    renderPatternListInto(el, { SEVERE: c.patterns || [] });
  }

  function renderCoho(c) {
    var el = $('cohoBody');
    if (!c || !(c.stuck > 0)) {
      el.innerHTML = '<p class="meta">No CoHo stuck/drop signals in the current window.</p>';
      return;
    }
    var html = '<p>Stuck/drop: <strong>' + c.stuck + '</strong></p>';
    if (c.sample) html += '<p class="meta mono">' + escapeHtml(c.sample) + '</p>';
    html += '<table class="data"><thead><tr><th>Count</th><th>Name</th></tr></thead><tbody>';
    (c.topNames || []).forEach(function (r) {
      html += '<tr><td>' + r.count + '</td><td class="mono">' + escapeHtml(r.name) + '</td></tr>';
    });
    html += '</tbody></table>';
    el.innerHTML = html;
  }

  function renderApogee(a) {
    var el = $('apogeeBody');
    if (!a || !(a.events > 0)) {
      el.innerHTML = '<p class="meta">No Apogee signals in the current window.</p>';
      return;
    }
    var html = '<p>Events: <strong>' + a.events + '</strong> · UpdatePoints: <strong>' + a.updatePoints +
      '</strong> · Repetition: <strong>' + a.repetition + '</strong> · Other: <strong>' + (a.other || 0) +
      '</strong> · unique PPCL: <strong>' + a.uniquePpcl + '</strong></p>';
    if (a.sample) html += '<p class="meta mono">' + escapeHtml(a.sample) + '</p>';
    html += '<table class="data"><thead><tr><th>Count</th><th>PPCL</th></tr></thead><tbody>';
    (a.topPpcl || []).forEach(function (r) {
      html += '<tr><td>' + r.count + '</td><td class="mono">' + escapeHtml(r.name) + '</td></tr>';
    });
    html += '</tbody></table>';
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

  function pollPulse() {
    var headersNote = '';
    var url = '/api/pulse?' + qsPulse();
    if (state.generation != null && !state.useMock) {
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
        return;
      }
      var prev = state.generation;
      applyPulse(res.json);
      if (state.activeView !== 'overview' && res.json.generation !== prev) {
        loadSection(state.activeView);
        if (state.activeView === 'managers' && state.selectedManager) {
          loadManagerDetail(state.selectedManager);
        }
      }
    }).catch(function (e) {
      setBanner('bannerError', String(e.message || e));
      setStatus('<span class="err">poll failed</span>');
    });
  }

  function startPolling() {
    stopPolling();
    state.pollTimer = setInterval(pollPulse, 3000);
    pollPulse();
  }

  function stopPolling() {
    if (state.pollTimer) clearInterval(state.pollTimer);
    state.pollTimer = null;
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
    });
  }

  function showLoading(msg) {
    setBanner('bannerLoading', msg || 'Loading window…');
    setStatus('<span class="warn">loading</span> · waiting for host…');
  }

  function requestWindowChange() {
    syncWindowButtons();
    if (!state.running && !state.useMock) {
      return;
    }
    // Show loading immediately — do not wait for the host (catch-up can take many seconds).
    showLoading(state.windowEntire ? 'Loading entire file… 0%' : ('Loading last ' + state.lastMinutes + ' minutes… 0%'));
    if (state.useMock) {
      pollPulse();
      return;
    }
    apiPost('/api/control', {
      action: 'setWindow',
      window: state.windowEntire ? 'entire' : 'minutes',
      lastMinutes: state.lastMinutes
    }).then(function () {
      pollPulse();
    }).catch(function (e) {
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
        if (state.running || state.useMock) {
          showLoading('Updating filters…');
          pollPulse().then(function () {
            if (state.activeView !== 'overview') loadSection(state.activeView);
          });
        }
      });
    });

    document.querySelectorAll('#windowPresets .chip').forEach(function (b) {
      b.addEventListener('click', function () {
        if (b.getAttribute('data-entire') === '1') {
          state.windowEntire = true;
        } else {
          state.windowEntire = false;
          state.lastMinutes = parseInt(b.getAttribute('data-minutes'), 10);
          $('customMinutes').value = '';
        }
        requestWindowChange();
      });
    });

    $('btnApplyWindow').addEventListener('click', function () {
      var n = parseInt($('customMinutes').value, 10);
      if (!n || n < 1) return;
      state.windowEntire = false;
      state.lastMinutes = Math.min(10080, n);
      requestWindowChange();
    });
    $('customMinutes').addEventListener('keydown', function (e) {
      if (e.key === 'Enter') $('btnApplyWindow').click();
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
      apiPost('/api/logPath', body).then(function () {
        state.running = true;
        state.starting = false;
        updateChromeButtons();
        startPolling();
        pollPulse();
      }).catch(function (e) {
        state.starting = false;
        state.running = false;
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
    $('btnRestart').addEventListener('click', function () {
      stopPolling();
      state.starting = false;
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
      }).catch(function (e) {
        setBanner('bannerError', String(e.message || e));
      });
    });
  }

  function boot() {
    bindUi();
    syncWindowButtons();
    updateChromeButtons();
    if (state.useMock) {
      setStatus('Mock mode — press Start to load sample dashboard');
      return;
    }
    apiGet('/api/health').then(function (res) {
      var h = res.json || {};
      if (h.prefillPath) $('logPath').value = h.prefillPath;
      if (h.listeningUrl) setStatus('Idle — host ' + escapeHtml(h.listeningUrl));
    }).catch(function () {
      setStatus('Idle — host not reachable (open via Run-Watch.cmd)');
    });
  }

  boot();
})();
