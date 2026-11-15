#if os(macOS)
/// Self-contained HTML report; `__BENCH_DATA__` is replaced by the run JSON.
let reportTemplate = #"""
<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>VimKit Bench</title>
<style>
:root{--bg:#f6f6f3;--surface:#fff;--surface2:#efefea;--text:#1d1d1f;--muted:#6b6b70;--border:#e0e0da;--accent:#3366dd;--on-accent:#fff;--warn:#b86e12;--bad:#cc3b30;--good:#1f8a57;--bar:#3366dd;--bar-slow:#cc3b30;--budget:#b86e12}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){--bg:#121214;--surface:#1b1b1e;--surface2:#26262a;--text:#ececef;--muted:#9a9aa3;--border:#2f2f34;--accent:#7ea4ff;--on-accent:#0b1430;--warn:#e9a54f;--bad:#ff6f61;--good:#4fc68e;--bar:#7ea4ff;--bar-slow:#ff6f61;--budget:#e9a54f}}
:root[data-theme="dark"]{--bg:#121214;--surface:#1b1b1e;--surface2:#26262a;--text:#ececef;--muted:#9a9aa3;--border:#2f2f34;--accent:#7ea4ff;--on-accent:#0b1430;--warn:#e9a54f;--bad:#ff6f61;--good:#4fc68e;--bar:#7ea4ff;--bar-slow:#ff6f61;--budget:#e9a54f}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--text);font:14px/1.45 -apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif}
main{max-width:1320px;margin:0 auto;padding:24px 16px 64px}
h1{font-size:22px;margin:0 0 6px;letter-spacing:-.01em}
h2{font-size:16px;margin:32px 0 10px}
.meta{color:var(--muted);font-size:13px;display:flex;flex-wrap:wrap;gap:4px 16px}
.banner{margin:14px 0;padding:10px 12px;border-radius:10px;border:1px solid var(--warn);color:var(--warn);background:var(--surface)}
.kpis{display:grid;grid-template-columns:repeat(auto-fit,minmax(190px,1fr));gap:10px;margin:18px 0 6px}
.kpi{background:var(--surface);border:1px solid var(--border);border-radius:12px;padding:12px 14px;min-width:0}
.kpi .label{color:var(--muted);font-size:12px}
.kpi .value{font-size:22px;font-weight:600;font-variant-numeric:tabular-nums;margin:2px 0}
.kpi .sub{color:var(--muted);font-size:12px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.controls{position:sticky;top:0;z-index:5;background:var(--bg);padding:10px 0;display:flex;flex-wrap:wrap;gap:8px 14px;align-items:center;border-bottom:1px solid var(--border)}
.seg{display:inline-flex;border:1px solid var(--border);border-radius:8px;overflow:hidden;background:var(--surface)}
.seg button{border:0;background:transparent;color:var(--text);padding:6px 11px;font:inherit;cursor:pointer}
.seg button+button{border-left:1px solid var(--border)}
.seg button.on{background:var(--accent);color:var(--on-accent)}
select{font:inherit;padding:5px 8px;border-radius:8px;border:1px solid var(--border);background:var(--surface);color:var(--text);max-width:100%}
.chk{display:inline-flex;gap:6px;align-items:center;color:var(--muted);cursor:pointer}
.card{background:var(--surface);border:1px solid var(--border);border-radius:12px;padding:14px}
.chart .row{display:grid;grid-template-columns:minmax(110px,260px) 1fr 96px;gap:10px;align-items:center;min-height:22px}
.chart .name{white-space:nowrap;overflow:hidden;text-overflow:ellipsis;font-size:13px}
.chart .name small{color:var(--muted)}
.chart .track{position:relative;height:12px;background:var(--surface2);border-radius:3px}
.chart .fill{position:absolute;left:0;top:0;bottom:0;border-radius:3px;background:var(--bar);min-width:2px}
.chart .fill.slow{background:var(--bar-slow)}
.chart .budget{position:absolute;top:-5px;bottom:-5px;border-left:2px dashed var(--budget)}
.chart .val{text-align:right;font-variant-numeric:tabular-nums;font-size:13px}
.legend{display:flex;flex-wrap:wrap;gap:14px;color:var(--muted);font-size:12px;margin-top:10px}
.legend i{display:inline-block;width:12px;height:10px;border-radius:2px;margin-right:5px;vertical-align:-1px}
.tablewrap{overflow-x:auto;border:1px solid var(--border);border-radius:12px;background:var(--surface)}
table{border-collapse:collapse;width:100%;font-size:13px;font-variant-numeric:tabular-nums}
th,td{padding:6px 9px;border-bottom:1px solid var(--border);text-align:right;white-space:nowrap}
tr:last-child td{border-bottom:0}
th{background:var(--surface);color:var(--muted);font-weight:500;cursor:pointer;user-select:none;position:sticky;top:0}
th.sorted{color:var(--text)}
th.l,td.l{text-align:left}
td code{font:12px ui-monospace,SFMono-Regular,Menlo,monospace;color:var(--muted)}
tr.group td{background:var(--surface2);color:var(--muted);font-weight:500;text-align:left}
.bad{color:var(--bad)}.good{color:var(--good)}.warn{color:var(--warn)}.muted{color:var(--muted)}
details{margin-top:28px;color:var(--text)}
details summary{cursor:pointer;font-weight:600}
dl{display:grid;grid-template-columns:max-content 1fr;gap:6px 16px;margin:12px 0 0}
dt{color:var(--muted)}
dd{margin:0}
.hist{display:flex;align-items:flex-end;gap:10px;overflow-x:auto;min-height:220px;padding-top:24px}
.hist .col{display:flex;flex-direction:column;align-items:center;justify-content:flex-end;min-width:56px;flex:0 0 auto;height:200px}
.hist .bar{width:34px;border-radius:4px 4px 0 0;min-height:2px}
.hist .v{font-size:12px;font-variant-numeric:tabular-nums;margin-bottom:4px;white-space:nowrap}
.hist .n{font-size:12px;color:var(--muted);margin-top:6px;text-align:center;line-height:1.2}
.chip{display:inline-block;padding:1px 7px;border-radius:999px;font-size:12px;color:#fff}
td.note{white-space:normal;min-width:220px;max-width:420px}
@media (max-width:640px){.chart .row{grid-template-columns:100px 1fr 72px}.kpi .value{font-size:19px}}
</style>
</head>
<body>
<main>
  <h1>VimKit · стенд производительности</h1>
  <div class="meta" id="meta"></div>
  <div id="banners"></div>
  <div class="controls" id="controls"></div>
  <div class="kpis" id="kpis"></div>

  <h2 id="chartTitle">Операции</h2>
  <div class="card chart" id="chart"></div>

  <h2>Все метрики</h2>
  <div class="tablewrap"><table id="table"></table></div>

  <h2>Жизненный цикл и память на экземпляр</h2>
  <div class="tablewrap"><table id="lifecycle"></table></div>

  <h2>История прогонов</h2>
  <div class="controls" style="position:static;border:0;padding:0 0 10px"><select id="histOp"></select><div class="seg" id="histMetric"></div><span class="muted" id="histScope"></span></div>
  <div class="card hist" id="historyChart"></div>
  <div class="tablewrap" style="margin-top:12px"><table id="historyTable"></table></div>

  <details>
    <summary>Как читать метрики</summary>
    <dl>
      <dt>Время</dt><dd>Стенные часы на один повтор операции (все её клавиши). Медиана, 95-й процентиль, максимум и первый повтор (холодный: JIT, первая раскладка).</dd>
      <dt>Движок / Вьюха</dt><dd>Движок — только <code>VimEngine</code> (JavaScriptCore + vim.js). Вьюха — <code>VimTextView</code> в окне: событие клавиши → движок → своя раскладка (VimTextLayout) → отрисовка окна.</dd>
      <dt>CPU</dt><dd>Процессорное время главного потока на повтор (медиана). «CPU процесса» — все потоки, включая сборщик мусора JavaScriptCore и AppKit.</dd>
      <dt>Инструкции, IPC</dt><dd>Выполненные инструкции процесса на повтор (счётчики ядра) и инструкций за такт. Не зависят от частоты и нагрузки машины — лучшая метрика для сравнения прогонов.</dd>
      <dt>Энергия</dt><dd>Оценка: такты процессора на операцию × энергия на такт. Энергию на такт стенд берёт из счётчика, которую macOS начисляет процессу (<code>ri_energy_nj</code>), за весь прогон. Сам счётчик обновляется раз в несколько миллисекунд, поэтому короткие операции напрямую им не измерить. В микроджоулях.</dd>
      <dt>Пик памяти</dt><dd>Насколько physical footprint процесса поднимался во время повторов над уровнем до операции. Опрашивается фоновым потоком каждые 0,5 мс и до/после каждого повтора.</dd>
      <dt>Удержано</dt><dd>Footprint после всех повторов минус footprint до них. Для жизненного цикла показан на один экземпляр (экземпляры удерживаются до конца замера).</dd>
      <dt>malloc</dt><dd>Изменение байт, выделенных через malloc во всех зонах. Кучу JavaScriptCore не включает — она видна в footprint.</dd>
      <dt>&gt;16,7 мс</dt><dd>Сколько повторов не уложились в кадр 60 Гц.</dd>
      <dt>Рост</dt><dd>Во сколько раз медиана на самом большом документе больше, чем на самом маленьком. Красный — операция дорожает почти пропорционально размеру файла.</dd>
      <dt>Доля UI</dt><dd>Какая часть времени операции во вьюхе приходится не на движок (TextKit, раскладка, отрисовка, синхронизация).</dd>
      <dt>Δ</dt><dd>Изменение медианы относительно базового прогона. Цветом выделено, только если время изменилось на 10%+ (и 0,05 мс+), а инструкции — на 5%+ в ту же сторону. Если инструкции те же, разница во времени — это частота процессора, нагрев или фоновая нагрузка, а не код (подсказка у значения показывает Δ инструкций).</dd>
    </dl>
  </details>
</main>
<script>
const DATA = __BENCH_DATA__;
const HISTORY = DATA.history || [];
const LANG_COLORS = ['#3366dd', '#d9822b', '#1f9e6b', '#9b51e0', '#cc3b30', '#0f9fb5', '#a1761a'];
const LANGS = [...new Set(HISTORY.map(h => h.meta.language || '—'))];
const langColor = l => LANG_COLORS[Math.max(0, LANGS.indexOf(l || '—')) % LANG_COLORS.length];
const chip = l => `<span class="chip" style="background:${langColor(l)}">${esc(l || '—')}</span>`;
const RUN = DATA.run, META = RUN.meta, ALL = RUN.results;
const keyOf = r => [r.level, r.lines, r.category, r.name].join('|');
const BASE = new Map(((DATA.baseline && DATA.baseline.results) || []).map(r => [keyOf(r), r]));
const OPS = ALL.filter(r => !r.lifecycle);
const LIFE = ALL.filter(r => r.lifecycle);
const SIZES = [...new Set(OPS.map(r => r.lines))].sort((a, b) => a - b);
const LEVELS = [...new Set(OPS.map(r => r.level))];
const CATS = [...new Set(OPS.map(r => r.category))];
const LEVEL_LABEL = {engine: 'Движок', view: 'Вьюха'};
const FRAME = 1000 / 60;
const INDEX = new Map(ALL.map(r => [keyOf(r), r]));

// Share of wall time spent off the CPU, over [wall, cpu] pairs.
function waitShare(pairs) { let w = 0, c = 0; pairs.forEach(([a, b]) => { w += a; c += Math.min(a, b); }); return w > 0 ? 1 - c / w : 0; }
const nf = (v, d) => v.toLocaleString('ru-RU', {maximumFractionDigits: d, minimumFractionDigits: d});
function ms(v) { if (v == null) return '—'; const a = Math.abs(v); return nf(v, a >= 100 ? 0 : a >= 10 ? 1 : a >= 1 ? 2 : 3); }
function count(v) { if (!v) return '0'; if (v >= 1e9) return nf(v / 1e9, 2) + ' млрд'; if (v >= 1e6) return nf(v / 1e6, 2) + ' млн'; if (v >= 1e3) return nf(v / 1e3, 1) + ' тыс'; return nf(v, 0); }
function mb(v) { return Math.abs(v) < 0.005 ? '0' : nf(v, Math.abs(v) >= 100 ? 0 : 2); }
function uj(v) { return v >= 1000 ? nf(v / 1000, 2) + ' мДж' : nf(v, v >= 10 ? 0 : 1) + ' мкДж'; }
const esc = s => String(s).replace(/[&<>"]/g, c => ({'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;'}[c]));

const METRICS = {
  wallMedian: {label: 'Время, медиана', fmt: v => ms(v) + ' мс', time: true},
  wallP95: {label: 'Время, p95', fmt: v => ms(v) + ' мс', time: true},
  wallMax: {label: 'Время, максимум', fmt: v => ms(v) + ' мс', time: true},
  wallFirst: {label: 'Первый (холодный) повтор', fmt: v => ms(v) + ' мс', time: true},
  cpuMedian: {label: 'CPU главного потока', fmt: v => ms(v) + ' мс', time: true},
  processCpuPerOp: {label: 'CPU процесса', fmt: v => ms(v) + ' мс', time: true},
  instructionsPerOp: {label: 'Инструкции', fmt: count},
  energyPerOpUJ: {label: 'Энергия (оценка)', fmt: uj},
  peakMB: {label: 'Пик памяти', fmt: v => mb(v) + ' МБ'},
  retainedMB: {label: 'Удержано памяти', fmt: v => mb(v) + ' МБ'},
  mallocKB: {label: 'Прирост malloc', fmt: v => nf(v, 0) + ' КБ'},
};

const state = {level: LEVELS.includes('view') ? 'view' : LEVELS[0], lines: SIZES[SIZES.length - 1], cat: 'all', metric: 'wallMedian', log: true, sort: 'wallMedian', dir: -1};
try { Object.assign(state, JSON.parse(localStorage.getItem('vimkit-bench') || '{}')); } catch (e) {}
if (!LEVELS.includes(state.level)) state.level = LEVELS[0];
if (!SIZES.includes(state.lines)) state.lines = SIZES[SIZES.length - 1];
if (!METRICS[state.metric]) state.metric = 'wallMedian';
function save() { try { localStorage.setItem('vimkit-bench', JSON.stringify(state)); } catch (e) {} }

function sibling(r, changes) { return INDEX.get(keyOf(Object.assign({}, r, changes))); }
function growth(r) {
  if (SIZES.length < 2) return null;
  const a = sibling(r, {lines: SIZES[0]}), b = sibling(r, {lines: SIZES[SIZES.length - 1]});
  if (!a || !b || a.wallMedian <= 0) return null;
  return b.wallMedian / a.wallMedian;
}
function uiShare(r) {
  if (r.level !== 'view') return null;
  const e = sibling(r, {level: 'engine'});
  if (!e || r.wallMedian <= 0) return null;
  return Math.max(0, (r.wallMedian - e.wallMedian) / r.wallMedian);
}
function delta(r) {
  const b = BASE.get(keyOf(r));
  if (!b || b.wallMedian <= 0) return null;
  const di = b.instructionsPerOp > 0 ? (r.instructionsPerOp - b.instructionsPerOp) / b.instructionsPerOp : 0;
  const d = (r.wallMedian - b.wallMedian) / b.wallMedian;
  // Time alone moves with CPU frequency and load; count it only when instructions moved the same way.
  const noise = Math.abs(d) < 0.1 || Math.abs(r.wallMedian - b.wallMedian) < 0.05 || Math.abs(di) < 0.05 || Math.sign(di) !== Math.sign(d);
  return {d: d, di: di, abs: r.wallMedian - b.wallMedian, noise: noise};
}

function renderMeta() {
  const m = META;
  if (m.runNumber) document.querySelector('h1').innerHTML = `VimKit · стенд производительности · прогон №${m.runNumber} ${chip(m.language)}`;
  const parts = [m.note ? 'Изменение: ' + m.note : null, m.chip, `${m.performanceCores}P + ${m.efficiencyCores}E ядер`, `${nf(m.memoryGB, 0)} ГБ`, m.os, `сборка ${m.build}`, `коммит ${m.commit}`,
    new Date(m.date).toLocaleString('ru-RU'), `${nf(m.durationSeconds, 0)} с на прогон`, `footprint на старте ${nf(m.baseFootprintMB, 0)} МБ`];
  if (m.averagePowerW) parts.push(`средняя мощность процесса ${nf(m.averagePowerW, 1)} Вт, ${nf(m.nanojoulesPerCycle * 1000, 1)} пДж на такт`);
  if (m.quick) parts.push('быстрый режим (--quick)');
  document.getElementById('meta').innerHTML = parts.filter(Boolean).map(p => `<span>${esc(p)}</span>`).join('');
  const banners = [];
  const ws = waitShare(OPS.map(r => [r.wallMedian, r.cpuMedian]));
  if (ws > 0.08 || (m.pageins || 0) > 5000) banners.push(`Во время прогона машину грузило что-то ещё: ${nf(ws * 100, 0)}% стенного времени операции ждали, а не считали${m.loadAverageStart != null ? `; load average ${nf(m.loadAverageStart, 1)} → ${nf(m.loadAverageEnd || 0, 1)}, подкачка ${m.pageins || 0} страниц, ${nf(m.effectiveGHz || 0, 2)} ГГц` : ''}. Стенное время завышено — сравнивайте CPU и инструкции.`);
  if (m.build !== 'release') banners.push('Отладочная сборка: цифры завышены в разы. Для реальных замеров: <code>swift run -c release VimKitBench</code>.');
  const broken = ALL.filter(r => !r.inSync || r.jsErrors > 0);
  if (broken.length) banners.push(`Проблемы в ${broken.length} замерах: ` + broken.slice(0, 6).map(r => `${esc(r.name)} (${LEVEL_LABEL[r.level]}, ${r.lines}: ${!r.inSync ? 'вьюха и движок разошлись' : 'ошибок JS ' + r.jsErrors})`).join('; '));
  if (DATA.baseline) banners.push(`Δ — сравнение с прогоном ${DATA.baseline.meta.runNumber ? '№' + DATA.baseline.meta.runNumber + ', ' : ''}${new Date(DATA.baseline.meta.date).toLocaleString('ru-RU')} (коммит ${esc(DATA.baseline.meta.commit)}).`);
  document.getElementById('banners').innerHTML = banners.map((b, i) => `<div class="banner" style="${i === banners.length - 1 && DATA.baseline ? 'border-color:var(--border);color:var(--muted)' : ''}">${b}</div>`).join('');
}

function renderControls() {
  const seg = (name, items, current) => `<div class="seg">${items.map(([v, l]) => `<button data-${name}="${v}" class="${String(v) === String(current) ? 'on' : ''}">${esc(l)}</button>`).join('')}</div>`;
  document.getElementById('controls').innerHTML =
    seg('level', LEVELS.map(l => [l, LEVEL_LABEL[l]]), state.level) +
    seg('lines', SIZES.map(s => [s, nf(s, 0) + ' строк']), state.lines) +
    `<select id="cat"><option value="all">Все категории</option>${CATS.map(c => `<option ${c === state.cat ? 'selected' : ''}>${esc(c)}</option>`).join('')}</select>` +
    `<select id="metric">${Object.entries(METRICS).map(([k, m]) => `<option value="${k}" ${k === state.metric ? 'selected' : ''}>${m.label}</option>`).join('')}</select>` +
    `<label class="chk"><input type="checkbox" id="log" ${state.log ? 'checked' : ''}> логарифмическая шкала</label>`;
  document.querySelectorAll('[data-level]').forEach(b => b.onclick = () => { state.level = b.dataset.level; update(); });
  document.querySelectorAll('[data-lines]').forEach(b => b.onclick = () => { state.lines = +b.dataset.lines; update(); });
  document.getElementById('cat').onchange = e => { state.cat = e.target.value; update(); };
  document.getElementById('metric').onchange = e => { state.metric = e.target.value; state.sort = e.target.value; state.dir = -1; update(); };
  document.getElementById('log').onchange = e => { state.log = e.target.checked; update(); };
}

function current() {
  return OPS.filter(r => r.level === state.level && r.lines === state.lines && (state.cat === 'all' || r.category === state.cat));
}

function renderKpis() {
  const rows = current().filter(r => r.category !== 'Стенд');
  const kpi = (label, value, sub, cls) => `<div class="kpi"><div class="label">${label}</div><div class="value ${cls || ''}">${value}</div><div class="sub">${sub || '&nbsp;'}</div></div>`;
  if (!rows.length) { document.getElementById('kpis').innerHTML = ''; return; }
  const by = k => rows.slice().sort((a, b) => b[k] - a[k]);
  const slowest = by('wallMedian')[0];
  const median = a => { const s = a.slice().sort((x, y) => x - y); const m = s.length >> 1; return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2; };
  const inFrame = rows.filter(r => r.wallP95 <= FRAME).length;
  const peak = by('peakMB')[0];
  const energy = median(rows.map(r => r.energyPerOpUJ));
  let html = kpi('Операций в выборке', rows.length, `${nf(rows.reduce((s, r) => s + r.repeats, 0), 0)} повторов`) +
    kpi('Медиана по операциям', ms(median(rows.map(r => r.wallMedian))) + ' мс', `CPU ${ms(median(rows.map(r => r.cpuMedian)))} мс · ${count(median(rows.map(r => r.instructionsPerOp)))} инстр.`) +
    kpi('В кадр 16,7 мс (p95)', `${inFrame} из ${rows.length}`, inFrame < rows.length ? 'остальные — красным' : 'все укладываются', inFrame < rows.length ? 'warn' : 'good') +
    kpi('Самая медленная', ms(slowest.wallMedian) + ' мс', esc(slowest.name)) +
    kpi('Пик памяти', mb(peak.peakMB) + ' МБ', esc(peak.name)) +
    kpi('Энергия на операцию', energy > 0 ? uj(energy) : '—', energy > 0 ? 'медиана' : 'ОС не сообщает энергию');
  if (DATA.baseline) {
    const ds = rows.map(delta).filter(d => d && !d.noise);
    const worse = ds.filter(d => d.d > 0.1).length, better = ds.filter(d => d.d < -0.1).length;
    html += kpi('Против прошлого прогона', `<span class="bad">${worse}</span> / <span class="good">${better}</span>`, 'медленнее / быстрее (время и инструкции)');
  }
  document.getElementById('kpis').innerHTML = html;
}

function renderChart() {
  const m = METRICS[state.metric];
  const rows = current().slice().sort((a, b) => b[state.metric] - a[state.metric]);
  document.getElementById('chartTitle').textContent = `${m.label} · ${LEVEL_LABEL[state.level]} · ${nf(state.lines, 0)} строк`;
  const values = rows.map(r => Math.max(0, r[state.metric]));
  const max = Math.max(...values, m.time ? FRAME : 0, 1e-9);
  const positive = values.filter(v => v > 0);
  const min = positive.length ? Math.min(...positive) : max / 10;
  const lo = Math.min(min, max / 10) / 1.5;
  const pos = v => {
    if (v <= 0) return 0;
    if (!state.log) return v / max * 100;
    return Math.max(0, Math.log(v / lo) / Math.log(max / lo) * 100);
  };
  const budget = m.time && state.metric !== 'cpuMedian' && state.metric !== 'processCpuPerOp' ? pos(FRAME) : null;
  document.getElementById('chart').innerHTML = rows.map(r => {
    const v = r[state.metric];
    const slow = m.time && r.wallP95 > FRAME;
    return `<div class="row" title="${esc(r.category)} · ${esc(r.keys || r.name)}"><div class="name">${esc(r.name)} <small>${esc(r.category)}</small></div>` +
      `<div class="track"><div class="fill ${slow ? 'slow' : ''}" style="width:${pos(v).toFixed(2)}%"></div>${budget != null ? `<div class="budget" style="left:${budget.toFixed(2)}%"></div>` : ''}</div>` +
      `<div class="val">${m.fmt(v)}</div></div>`;
  }).join('') + `<div class="legend"><span><i style="background:var(--bar)"></i>p95 в пределах кадра</span><span><i style="background:var(--bar-slow)"></i>p95 больше 16,7 мс</span>${budget != null ? '<span><i style="border-left:2px dashed var(--budget);border-radius:0;background:none"></i>бюджет кадра 60 Гц</span>' : ''}${state.log ? '<span>шкала логарифмическая</span>' : ''}</div>`;
}

const COLUMNS = [
  {k: 'name', l: 'Операция', cls: 'l', v: r => r.name, f: r => `${esc(r.name)}${r.keys && r.keys !== r.name ? ` <code>${esc(r.keys)}</code>` : ''}`},
  {k: 'category', l: 'Категория', cls: 'l', v: r => r.category, f: r => `<span class="muted">${esc(r.category)}</span>`},
  {k: 'wallMedian', l: 'Медиана, мс', v: r => r.wallMedian, f: r => `<span class="${r.wallMedian > FRAME ? 'bad' : ''}">${ms(r.wallMedian)}</span>`},
  {k: 'wallP95', l: 'p95', v: r => r.wallP95, f: r => `<span class="${r.wallP95 > FRAME ? 'bad' : ''}">${ms(r.wallP95)}</span>`},
  {k: 'wallMax', l: 'Макс', v: r => r.wallMax, f: r => ms(r.wallMax)},
  {k: 'wallFirst', l: 'Первый', v: r => r.wallFirst, f: r => ms(r.wallFirst)},
  {k: 'cpuMedian', l: 'CPU гл. потока', v: r => r.cpuMedian, f: r => ms(r.cpuMedian)},
  {k: 'processCpuPerOp', l: 'CPU процесса', v: r => r.processCpuPerOp, f: r => ms(r.processCpuPerOp)},
  {k: 'instructionsPerOp', l: 'Инструкции', v: r => r.instructionsPerOp, f: r => count(r.instructionsPerOp)},
  {k: 'ipc', l: 'IPC', v: r => r.cyclesPerOp ? r.instructionsPerOp / r.cyclesPerOp : 0, f: r => r.cyclesPerOp ? nf(r.instructionsPerOp / r.cyclesPerOp, 2) : '—'},
  {k: 'energyPerOpUJ', l: 'Энергия', v: r => r.energyPerOpUJ, f: r => r.energyPerOpUJ > 0 ? uj(r.energyPerOpUJ) : '—'},
  {k: 'peakMB', l: 'Пик, МБ', v: r => r.peakMB, f: r => mb(r.peakMB)},
  {k: 'retainedMB', l: 'Удержано, МБ', v: r => r.retainedMB, f: r => mb(r.retainedMB)},
  {k: 'mallocKB', l: 'malloc, КБ', v: r => r.mallocKB, f: r => nf(r.mallocKB, 0)},
  {k: 'hitches', l: '>16,7 мс', v: r => r.hitches, f: r => r.hitches ? `<span class="bad">${r.hitches}/${r.repeats}</span>` : `<span class="muted">0/${r.repeats}</span>`},
  {k: 'growth', l: 'Рост', v: r => growth(r) || 0, f: r => { const g = growth(r); if (g == null) return '—'; const ratio = SIZES[SIZES.length - 1] / SIZES[0]; return `<span class="${g > ratio * 0.3 ? 'bad' : g > 3 ? 'warn' : ''}">×${nf(g, 1)}</span>`; }},
  {k: 'ui', l: 'Доля UI', v: r => uiShare(r) || 0, f: r => { const u = uiShare(r); return u == null ? '—' : nf(u * 100, 0) + '%'; }},
  {k: 'delta', l: 'Δ', v: r => (delta(r) || {d: 0}).d, f: r => { const d = delta(r); if (!d) return '—'; return `<span class="${d.noise ? 'muted' : d.d > 0 ? 'bad' : 'good'}" title="инструкции ${d.di > 0 ? '+' : ''}${nf(d.di * 100, 0)}%${d.noise ? ' — шум' : ''}">${d.d > 0 ? '+' : ''}${nf(d.d * 100, 0)}%</span>`; }},
  {k: 'ok', l: 'Проверка', v: r => (r.inSync && !r.jsErrors) ? 1 : 0, f: r => !r.inSync ? '<span class="bad">рассинхрон</span>' : r.jsErrors ? `<span class="bad" title="${esc(r.firstError || '')}">JS: ${r.jsErrors}</span>` : '<span class="good">✓</span>'},
];

function renderTable() {
  const cols = COLUMNS.filter(c => (c.k !== 'ui' || state.level === 'view') && (c.k !== 'delta' || DATA.baseline) && (c.k !== 'growth' || SIZES.length > 1));
  const col = cols.find(c => c.k === state.sort) || cols.find(c => c.k === 'wallMedian');
  const rows = current().slice().sort((a, b) => { const x = col.v(a), y = col.v(b); return (x > y ? 1 : x < y ? -1 : 0) * state.dir; });
  const t = document.getElementById('table');
  t.innerHTML = `<thead><tr>${cols.map(c => `<th data-k="${c.k}" class="${c.cls || ''} ${c === col ? 'sorted' : ''}">${c.l}${c === col ? (state.dir > 0 ? ' ↑' : ' ↓') : ''}</th>`).join('')}</tr></thead>` +
    `<tbody>${rows.map(r => `<tr>${cols.map(c => `<td class="${c.cls || ''}">${c.f(r)}</td>`).join('')}</tr>`).join('')}</tbody>`;
  t.querySelectorAll('th').forEach(th => th.onclick = () => {
    if (state.sort === th.dataset.k) state.dir = -state.dir; else { state.sort = th.dataset.k; state.dir = th.classList.contains('l') ? 1 : -1; }
    update();
  });
}

function renderLifecycle() {
  const t = document.getElementById('lifecycle');
  if (!LIFE.length) { t.innerHTML = '<tbody><tr><td class="l muted">Не измерялся (запуск с --filter).</td></tr></tbody>'; return; }
  const rows = LIFE.slice().sort((a, b) => a.lines - b.lines);
  const keeps = r => /^Создание|VimRuntime/.test(r.name);
  t.innerHTML = '<thead><tr><th class="l">Операция</th><th class="l">Уровень</th><th>Строк</th><th>Медиана, мс</th><th>Макс</th><th>Первый</th><th>CPU гл. потока</th><th>Инструкции</th><th>Энергия</th><th>Память на экземпляр, МБ</th><th>Пик, МБ</th><th>Проверка</th></tr></thead><tbody>' +
    rows.map(r => `<tr><td class="l">${esc(r.name)}</td><td class="l muted">${LEVEL_LABEL[r.level]}</td><td>${r.lines ? nf(r.lines, 0) : '—'}</td>` +
      `<td class="${r.wallMedian > FRAME ? 'warn' : ''}">${ms(r.wallMedian)}</td><td>${ms(r.wallMax)}</td><td>${ms(r.wallFirst)}</td><td>${ms(r.cpuMedian)}</td><td>${count(r.instructionsPerOp)}</td>` +
      `<td>${r.energyPerOpUJ > 0 ? uj(r.energyPerOpUJ) : '—'}</td><td>${keeps(r) ? mb(r.retainedPerRepeatMB) : '<span class="muted">—</span>'}</td><td>${mb(r.peakMB)}</td>` +
      `<td>${!r.inSync ? '<span class="bad">рассинхрон</span>' : r.jsErrors ? `<span class="bad">JS: ${r.jsErrors}</span>` : '<span class="good">✓</span>'}</td></tr>`).join('') + '</tbody>';
}

function renderHistory() {
  const chart = document.getElementById('historyChart'), table = document.getElementById('historyTable'), sel = document.getElementById('histOp');
  if (!HISTORY.length) { chart.innerHTML = '<span class="muted">Нет истории.</span>'; return; }
  const prefix = state.level + '|' + state.lines + '|';
  const names = current().map(r => r.category + '|' + r.name);
  if (!names.includes(state.histOp)) {
    // Default: the operation that was slowest in the first run.
    const first = HISTORY[0].values, ranked = names.slice().sort((a, b) => ((first[prefix + b] || [0])[0]) - ((first[prefix + a] || [0])[0]));
    state.histOp = ranked[0];
  }
  sel.innerHTML = names.slice().sort((a, b) => a.split('|')[1].localeCompare(b.split('|')[1])).map(n => `<option value="${esc(n)}" ${n === state.histOp ? 'selected' : ''}>${esc(n.split('|')[1])} — ${esc(n.split('|')[0])}</option>`).join('');
  sel.onchange = e => { state.histOp = e.target.value; update(); };
  const HM = [['0', 'Время'], ['1', 'CPU'], ['3', 'Инструкции']];
  if (!HM.some(x => x[0] === String(state.histMetric))) state.histMetric = '0';
  const mi = +state.histMetric, fmtH = v => mi === 3 ? count(v) : ms(v) + ' мс';
  document.getElementById('histMetric').innerHTML = HM.map(([v, l]) => `<button data-hm="${v}" class="${v === String(state.histMetric) ? 'on' : ''}">${l}</button>`).join('');
  document.querySelectorAll('[data-hm]').forEach(b => b.onclick = () => { state.histMetric = b.dataset.hm; update(); });
  document.getElementById('histScope').textContent = `медиана, ${LEVEL_LABEL[state.level].toLowerCase()}, ${nf(state.lines, 0)} строк · цвет — язык изменения · бледные столбцы — шумные прогоны`;
  const key = prefix + state.histOp;
  const pick = h => h.values[key] && h.values[key][mi] != null ? h.values[key][mi] : null;
  const points = HISTORY.map(h => ({meta: h.meta, v: pick(h)}));
  const histWait = h => waitShare(Object.entries(h.values).filter(([k]) => !k.includes('|Жизненный цикл|')).map(([, x]) => [x[0], x[1]]));
  HISTORY.forEach(h => { h.meta.$wait = histWait(h); });
  const isNoisy = m => m.$wait > 0.08 || (m.pageins || 0) > 5000;
  const max = Math.max(...points.map(p => p.v || 0), 1e-9);
  chart.innerHTML = points.map(p => `<div class="col" title="${esc(p.meta.note || '')}"><div class="v">${p.v == null ? '—' : fmtH(p.v)}</div>` +
    `<div class="bar" style="height:${p.v == null ? 0 : Math.max(1, p.v / max * 150).toFixed(1)}px;background:${langColor(p.meta.language)};${isNoisy(p.meta) ? 'opacity:.45' : ''}"></div>` +
    `<div class="n">№${p.meta.runNumber || '?'}${isNoisy(p.meta) ? ' ⚠︎' : ''}<br>${esc(p.meta.language || '—')}</div></div>`).join('');
  table.innerHTML = '<thead><tr><th class="l">№</th><th class="l">Дата</th><th class="l">Язык</th><th class="l">Что изменилось</th><th class="l">Коммит</th><th class="l">Сборка, режим</th><th class="l">Нагрузка</th><th>Выбранная операция</th><th>Δ к предыдущему</th><th>Медиана операций, мс</th></tr></thead><tbody>' +
    HISTORY.slice().reverse().map((h, i, arr) => {
      const v = pick(h), prev = arr[i + 1] ? pick(arr[i + 1]) : null;
      const d = v != null && prev ? (v - prev) / prev : null;
      const all = Object.entries(h.values).filter(([k]) => k.startsWith(prefix) && !k.startsWith(prefix + 'Стенд|') && !k.startsWith(prefix + 'Жизненный цикл|')).map(([, x]) => x[0]).sort((a, b) => a - b);
      const med = all.length ? all[all.length >> 1] : null;
      const mode = [h.meta.build, h.meta.quick ? '--quick' : null, h.meta.filter ? '--filter ' + h.meta.filter : null].filter(Boolean).join(', ');
      return `<tr><td class="l">${h.meta.runNumber || '—'}</td><td class="l">${new Date(h.meta.date).toLocaleString('ru-RU')}</td><td class="l">${chip(h.meta.language)}</td>` +
        `<td class="l note">${esc(h.meta.note || '—')}</td><td class="l"><code>${esc(h.meta.commit)}</code></td><td class="l muted">${esc(mode)}</td>` +
        `<td class="l ${isNoisy(h.meta) ? 'warn' : 'muted'}">${(isNoisy(h.meta) ? '⚠︎ ' : '') + 'ожидание ' + nf(h.meta.$wait * 100, 0) + '%'}${h.meta.loadAverageStart == null ? '' : ', load ' + nf(h.meta.loadAverageStart, 1) + '→' + nf(h.meta.loadAverageEnd || 0, 1) + ', подкачка ' + (h.meta.pageins || 0) + (h.meta.effectiveGHz ? ', ' + nf(h.meta.effectiveGHz, 2) + ' ГГц' : '')}</td>` +
        `<td>${v == null ? '—' : fmtH(v)}</td><td>${d == null ? '—' : `<span class="${Math.abs(d) < 0.1 ? 'muted' : d > 0 ? 'bad' : 'good'}">${d > 0 ? '+' : ''}${nf(d * 100, 0)}%</span>`}</td><td>${med == null ? '—' : ms(med)}</td></tr>`;
    }).join('') + '</tbody>';
}

function update() { save(); renderControls(); renderKpis(); renderChart(); renderTable(); renderHistory(); }
renderMeta(); renderLifecycle(); update();
</script>
</body>
</html>
"""#
#endif
