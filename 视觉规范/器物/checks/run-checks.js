'use strict';
/*
 * “器物”正式视觉规范离线检查，可复跑：
 *   node 视觉规范/器物/checks/run-checks.js
 *
 * A 静态检查：文件与脚本语法、页面结构与无障碍标注、外部资源、禁用接口、样式、色彩对比、推算规则，
 *   以及“规格”一章写的数值与样式表是否一致。
 * B 模拟交互：用同目录 mini-dom.js 的最小 DOM 跑页面脚本的主流程。
 * 两类检查都不渲染画面，不能代替真实浏览器里的视觉与交互验收；结尾会列出只能在浏览器里确认的项目。
 * 本脚本不联网、不写文件、不调用摄像头或麦克风。
 */

const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert');
const { createDocument, createClock, evt } = require('./mini-dom');

const ROOT = path.resolve(__dirname, '..');
const read = (file) => fs.readFileSync(path.join(ROOT, file), 'utf8');
const results = [];

function check(group, name, fn) {
  try {
    const detail = fn();
    results.push({ group, name, ok: true, detail: detail || '' });
  } catch (error) {
    results.push({ group, name, ok: false, detail: error.message });
  }
}

const html = read('index.html');
const css = read('instrument.css');
const js = read('instrument.js');

/* ================= A 静态检查 ================= */
const A1 = 'A1 文件与语法';
check(A1, '页面引用的样式与脚本文件存在', () => {
  const linked = [...html.matchAll(/<link[^>]+href="([^"]+\.css)"/g)].map((m) => m[1]);
  const scripts = [...html.matchAll(/<script[^>]+src="([^"]+)"/g)].map((m) => m[1]);
  assert.deepStrictEqual(linked, ['instrument.css']);
  assert.deepStrictEqual(scripts, ['instrument.js']);
  return '引用 instrument.css、instrument.js';
});
check(A1, '脚本可以编译', () => { new vm.Script(js, { filename: 'instrument.js' }); });

const A2 = 'A2 页面结构与无障碍标注';
const VOID = new Set(['area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'source', 'track', 'wbr']);
// 注释替换成等长空白，保证下面的位置与原文件一致
const htmlBare = html.replace(/<!--[\s\S]*?-->/g, (c) => c.replace(/[^\n]/g, ' '));
const tags = [...htmlBare.matchAll(/<(\/?)([a-zA-Z][\w:-]*)((?:\s+[^\s"'>/=]+(?:\s*=\s*(?:"[^"]*"|'[^']*'))?)*)\s*(\/?)>/g)];
const elements = tags.filter((t) => !t[1]).map((t) => {
  const attrs = {};
  for (const a of t[3].matchAll(/([^\s"'>/=]+)(?:\s*=\s*"([^"]*)")?/g)) attrs[a[1]] = a[2] === undefined ? '' : a[2];
  return { tag: t[2], attrs, index: t.index };
});
const ids = elements.filter((e) => 'id' in e.attrs).map((e) => e.attrs.id);
const idSet = new Set(ids);
check(A2, '标签成对闭合', () => {
  const stack = [];
  for (const t of tags) {
    const name = t[2].toLowerCase();
    if (VOID.has(name) || t[4]) continue;
    if (!t[1]) stack.push(name);
    else if (stack.pop() !== name) throw new Error(`</${name}> 位置不对（第 ${html.slice(0, t.index).split('\n').length} 行）`);
  }
  assert.strictEqual(stack.length, 0, `仍有未闭合：${stack.slice(-3).join(', ')}`);
});
check(A2, 'id 不重复', () => {
  const dup = ids.filter((id, i) => ids.indexOf(id) !== i);
  assert.deepStrictEqual(dup, []);
  return `${ids.length} 个 id`;
});
check(A2, '引用的 id、锚点与图标都存在', () => {
  const missing = [];
  for (const e of elements) {
    for (const key of ['aria-labelledby', 'aria-describedby', 'for']) {
      if (e.attrs[key]) e.attrs[key].split(/\s+/).forEach((ref) => { if (!idSet.has(ref)) missing.push(`${key}=${ref}`); });
    }
    const href = e.attrs.href;
    if (href && href.startsWith('#') && !idSet.has(href.slice(1))) missing.push(`href=${href}`);
  }
  for (const m of js.matchAll(/'#(i-[\w-]+)'/g)) if (!idSet.has(m[1])) missing.push(`脚本图标 ${m[1]}`);
  for (const m of js.matchAll(/\$\('#([\w-]+)'\)/g)) if (!idSet.has(m[1])) missing.push(`脚本元素 #${m[1]}`);
  assert.deepStrictEqual([...new Set(missing)], []);
});
check(A2, '本地链接指向的文件存在', () => {
  const bad = [];
  for (const e of elements) {
    for (const key of ['href', 'src']) {
      const v = e.attrs[key];
      if (!v || v.startsWith('#') || /^[a-z]+:/i.test(v)) continue;
      if (!fs.existsSync(path.resolve(ROOT, v.split('#')[0]))) bad.push(v);
    }
  }
  assert.deepStrictEqual(bad, []);
  return elements.filter((e) => e.tag === 'a' && e.attrs.href && !e.attrs.href.startsWith('#')).map((e) => e.attrs.href).join('、');
});
check(A2, '不引用外部地址', () => {
  const found = [html, css, js].flatMap((text) => [...text.matchAll(/https?:\/\/[^\s"')]+/g)].map((m) => m[0]))
    .filter((u) => u !== 'http://www.w3.org/2000/svg');
  assert.deepStrictEqual(found, [], '只允许 SVG 命名空间');
});
check(A2, '单选与开关带有状态标注', () => {
  const problems = [];
  const stack = [];
  for (const t of tags) {
    const name = t[2].toLowerCase();
    if (VOID.has(name) || t[4]) continue;
    if (!t[1]) stack.push({ name, isGroup: /role="radiogroup"/.test(t[3]) });
    else stack.pop();
    if (!t[1] && /role="radio"/.test(t[3]) && !stack.slice(0, -1).some((s) => s.isGroup)) problems.push(`radio 不在 radiogroup 内：${t[3].trim().slice(0, 60)}`);
    if (!t[1] && /role="(radio|switch)"/.test(t[3]) && !/aria-checked="(true|false)"/.test(t[3])) problems.push(`缺少 aria-checked：${t[3].trim().slice(0, 60)}`);
  }
  assert.deepStrictEqual(problems, []);
});
check(A2, '按钮带 type 与可读名称，输入框有标签', () => {
  const problems = [];
  const buttonRe = /<button([^>]*)>([\s\S]*?)<\/button>/g;
  for (const m of htmlBare.matchAll(buttonRe)) {
    const attrs = m[1];
    const text = m[2].replace(/<[^>]+>/g, '').trim();
    if (!/type="button"/.test(attrs)) problems.push(`缺少 type：${text || attrs.slice(0, 40)}`);
    if (!text && !/aria-label(ledby)?="[^"]+"|title="[^"]+"/.test(attrs)) problems.push(`没有名称：${attrs.slice(0, 60)}`);
  }
  for (const e of elements.filter((x) => x.tag === 'input' || x.tag === 'select')) {
    const before = htmlBare.slice(Math.max(0, e.index - 160), e.index);
    const labelled = e.attrs['aria-label'] || e.attrs['aria-labelledby'] || (e.attrs.id && html.includes(`for="${e.attrs.id}"`)) ||
      before.lastIndexOf('<label') > before.lastIndexOf('</label>');
    if (!labelled) problems.push(`${e.tag}#${e.attrs.id || '?'} 缺少标签`);
  }
  assert.deepStrictEqual(problems, []);
});
check(A2, '语言、编码与视口声明', () => {
  assert.ok(/<html lang="zh-CN">/.test(html), 'lang');
  assert.ok(/<meta charset="utf-8">/.test(html), 'charset');
  assert.ok(/name="viewport"/.test(html), 'viewport');
});

const A3 = 'A3 禁用接口与按键';
check(A3, '不使用媒体、网络、存储等接口', () => {
  const forbidden = /getUserMedia|getDisplayMedia|mediaDevices|navigator\.(permissions|clipboard|geolocation)|fetch\(|XMLHttpRequest|WebSocket|EventSource|sendBeacon|localStorage|sessionStorage|indexedDB|document\.cookie|Notification|eval\(|new Function|innerHTML|outerHTML|document\.write|import\(/;
  const hits = [['instrument.js', js], ['index.html', html], ['instrument.css', css]]
    .flatMap(([file, text]) => text.split('\n').map((line, i) => (forbidden.test(line) ? `${file}:${i + 1}` : null)).filter(Boolean));
  assert.deepStrictEqual(hits, []);
});
check(A3, '只处理 Esc、Tab、方向键与 Home/End，不绑定 ⌘R、⌘E', () => {
  const keys = new Set([...js.matchAll(/e\.key [!=]== '([A-Za-z]+)'/g)].map((m) => m[1]));
  const allowed = new Set(['Escape', 'Tab', 'ArrowRight', 'ArrowDown', 'ArrowLeft', 'ArrowUp', 'Home', 'End']);
  assert.deepStrictEqual([...keys].filter((k) => !allowed.has(k)), []);
  assert.ok(!/metaKey|ctrlKey|altKey|keyCode/.test(js), '出现修饰键判断');
  return [...keys].join('、');
});

/* 样式表解析：cssBare 去掉注释并清空字符串，只用于计数和查变量；
   rules 只去掉注释、保留属性选择器里的引号，用于按选择器取声明值。 */
const cssNoComments = css.replace(/\/\*[\s\S]*?\*\//g, '');
const cssBare = cssNoComments.replace(/"(?:[^"\\]|\\.)*"/g, '""');
const rules = [...cssNoComments.matchAll(/([^{}]+)\{([^{}]*)\}/g)].map((m) => {
  const decls = {};
  for (const d of m[2].split(';')) {
    const i = d.indexOf(':');
    if (i > 0) decls[d.slice(0, i).trim()] = d.slice(i + 1).trim().replace(/\s+/g, ' ');
  }
  return { selectors: m[1].split(',').map((s) => s.trim().replace(/\s+/g, ' ')), decls, body: m[2] };
});
// 取某个选择器第一次出现时的声明（基础规则写在媒体查询之前）
function decl(selector, prop) {
  for (const r of rules) if (r.selectors.includes(selector) && prop in r.decls) return r.decls[prop];
  throw new Error(`样式里找不到 ${selector} { ${prop} }`);
}
function hasRule(selector) { return rules.some((r) => r.selectors.includes(selector)); }

const A4 = 'A4 样式';
check(A4, '花括号成对', () => {
  let depth = 0;
  for (const ch of cssBare) { if (ch === '{') depth++; if (ch === '}') depth--; if (depth < 0) throw new Error('多出 }'); }
  assert.strictEqual(depth, 0);
});
check(A4, '用到的样式变量都有定义或兜底', () => {
  const defined = new Set([...cssBare.matchAll(/(--[\w-]+)\s*:/g)].map((m) => m[1]));
  for (const m of html.matchAll(/style="([^"]*)"/g)) for (const d of m[1].matchAll(/(--[\w-]+)\s*:/g)) defined.add(d[1]);
  for (const m of js.matchAll(/setProperty\('(--[\w-]+)'/g)) defined.add(m[1]);
  const missing = [...cssBare.matchAll(/var\((--[\w-]+)(\s*,[^)]*)?\)/g)].filter((m) => !m[2] && !defined.has(m[1])).map((m) => m[1]);
  assert.deepStrictEqual([...new Set(missing)], []);
  return `${defined.size} 个变量`;
});
check(A4, '脚本生成或切换的类名都有对应样式', () => {
  const made = new Set([
    ...[...js.matchAll(/className = '([\w-]+)'/g)].map((m) => m[1]),
    ...[...js.matchAll(/classList\.(?:add|toggle)\('([\w-]+)'/g)].map((m) => m[1]),
    ...[...js.matchAll(/restartAnimation\([^,]+, '([\w-]+)'\)/g)].map((m) => m[1])
  ]);
  const missing = [...made].filter((c) => !new RegExp(`\\.${c}(?![\\w-])`).test(cssBare));
  assert.deepStrictEqual(missing, []);
  return [...made].join('、');
});
check(A4, '信号橙只用于录制键、控制条录制灯与录制中的选区（另含封面与规格里的同款样本）', () => {
  const orange = /var\(--signal|#ee5a24|#f27040|#f47a4c|#f06430|rgba\((238, 90, 36|184, 67, 15)/i;
  const allowed = /^(:root|\.key-rec\b.*|\.t-key|\.hud-led|\.meter-led|\.led\.is-rec|\.region\[data-live="true"\].*|\.region-badge\.is-live::before)$/;
  const outside = rules.filter((r) => orange.test(r.body)).flatMap((r) => r.selectors).filter((s) => !allowed.test(s));
  assert.deepStrictEqual(outside, []);
  const jsColors = [...js.matchAll(/#[0-9a-fA-F]{6}\b|rgba?\(/g)].map((m) => m[0]);
  assert.deepStrictEqual(jsColors, [], '脚本里不应直接写颜色');
});
check(A4, '橙键上的字与录制符号都用石墨色', () => {
  assert.strictEqual(decl('.key-rec', 'color'), 'var(--graphite)');
  assert.strictEqual(decl('.key-cap', 'color'), 'var(--graphite)');
  assert.strictEqual(decl('.rec-lamp', 'background'), 'var(--graphite)');
  assert.strictEqual(decl('.t-key', 'color'), 'var(--graphite)');
});

const A5 = 'A5 色彩对比（按色值计算）';
const token = (name) => {
  const m = new RegExp(`${name}:\\s*(#[0-9a-fA-F]{6})`).exec(css);
  if (!m) throw new Error(`找不到 ${name}`);
  return m[1];
};
const rgb = (hex) => [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16));
const lum = (c) => { const [r, g, b] = c.map((v) => { v /= 255; return v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; }); return 0.2126 * r + 0.7152 * g + 0.0722 * b; };
const ratio = (a, b) => { const x = lum(a); const y = lum(b); return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05); };
const tint = (fg, alpha, bg) => fg.map((v, i) => Math.round(v * alpha + bg[i] * (1 - alpha)));
const T = (name) => rgb(token(name));
// 页面“色彩”一节的色卡说明：按色名取出 <figcaption> 里的文字
const swatchCaption = (name) => {
  const m = new RegExp(`<b>${name}</b><code>[^<]*</code><span>([^<]*)</span>`).exec(html);
  if (!m) throw new Error(`页面没有色卡“${name}”`);
  return m[1];
};
const darkKeyTop = rgb(/linear-gradient\(180deg, (#[0-9a-f]{6})/.exec(decl('.key-dark', 'background'))[1]);
const darkKeyText = rgb(decl('.key-dark', 'color'));
// [说明, 前景, 背景, 页面上写的数值出处（色卡名或 null）, 页面写法, 最低要求]
const pairs = [
  ['石墨 / 铝', T('--graphite'), T('--alu'), '石墨', '对铝 10.4:1', 4.5],
  ['次石墨 / 铝', T('--ink-2'), T('--alu'), '次石墨', '对铝 6.6:1', 4.5],
  ['刻字 / 铝', T('--engrave'), T('--alu'), '刻字', '对铝 5.1:1', 4.5],
  ['读数 / 显示窗', T('--readout'), T('--window'), '读数', '对窗 14.3:1', 4.5],
  ['暗读数 / 显示窗', T('--readout-dim'), T('--window'), '暗读数', '对窗 5.8:1', 4.5],
  ['石墨字 / 信号橙键面', T('--graphite'), T('--signal'), '信号橙', '石墨字于橙键 4.6:1', 4.5],
  ['警示 / 铝', T('--warn'), T('--alu'), '警示', '对铝 5.3:1', 4.5],
  ['完成 / 铝', T('--ok'), T('--alu'), '完成', '对铝 5.0:1', 4.5],
  ['指示灯亮 / 灭（非文字）', T('--led-on'), T('--led-off'), '指示灯 · 亮', '对灭灯 3.4:1', 3],
  ['深色大键：暖白字 / 键面最亮处', darkKeyText, darkKeyTop, null, '常态下对键面最亮处也在 10:1 以上', 10],
  ['刻字 / 未按下的键面最暗处（比例键）', T('--engrave'), rgb('#dedcd7'), null, null, 4.5],
  ['标注圆标字 / 铝上的淡蓝灰底', T('--anno-ink'), tint(T('--anno'), 0.1, T('--alu')), null, null, 4.5],
  ['标注标签字 / 标注底（叠在白色画面上的最浅情况）', T('--anno-text'), tint([28, 40, 56], 0.92, [255, 255, 255]), null, null, 4.5]
];
for (const [label, fg, bg, swatch, phrase, min] of pairs) {
  check(A5, label, () => {
    const value = ratio(fg, bg);
    assert.ok(value >= min, `${value.toFixed(2)} 低于 ${min}`);
    if (phrase) {
      const where = swatch ? swatchCaption(swatch) : html;
      assert.ok(where.includes(phrase), `页面没有写“${phrase}”`);
      const stated = /(\d+\.\d)(?=:1)/.exec(phrase);
      if (stated) assert.ok(Math.abs(value - Number(stated[1])) <= 0.06, `页面写 ${stated[1]}，实算 ${value.toFixed(2)}`);
    }
    return `${value.toFixed(2)}:1`;
  });
}
check(A5, '白字放在橙键上不达标（页面据此不采用）', () => {
  const value = ratio([255, 255, 255], T('--signal'));
  assert.ok(html.includes('白字只有 3.4:1，不采用'));
  assert.ok(Math.abs(value - 3.4) <= 0.06 && value < 4.5, `实算 ${value.toFixed(2)}`);
  return `${value.toFixed(2)}:1`;
});

const A6 = 'A6 推算规则（与软件 ExportPlanning 一致）';
const planningContext = { window: {}, console };
planningContext.globalThis = planningContext;
vm.createContext(planningContext);
vm.runInContext(js, planningContext, { filename: 'instrument.js' });
const P = planningContext.window.InstrumentPlanning;
check(A6, '脚本在无页面环境下导出 InstrumentPlanning', () => { assert.ok(P && typeof P.plan === 'function'); });
if (P) {
  const info = P.makeInfo({ mode: 'browser', windowKey: 'safari', duration: 134, hasSystemAudio: true, hasMicrophone: false });
  const merged = { tracks: new Set(['video', 'systemAudio']), arrangement: 'merged' };
  check(A6, '示例录制的体积估算', () => {
    assert.strictEqual(P.estimateText(info, merged, 'balanced', null), '最高 1920 × 1200 · 30 帧 · 视频约 100.2 MB');
    assert.strictEqual(P.estimateText(info, merged, 'maximum', null), '2560 × 1600 · 30 帧 · 视频约 194.3 MB');
  });
  check(A6, '横竖录制都按原始像素比例递减', () => {
    const balanced = P.plan({ size: { w: 3022, h: 1702 }, duration: 4, preset: 'balanced' }).size;
    const compact = P.plan({ size: { w: 3022, h: 1702 }, duration: 4, preset: 'compact' }).size;
    assert.strictEqual(`${balanced.w}x${balanced.h}`, '2264x1276');
    assert.strictEqual(`${compact.w}x${compact.h}`, '1508x850');
    const portrait = P.makeInfo({ mode: 'region', ratio: '9:16', duration: 60, hasSystemAudio: false, hasMicrophone: true });
    assert.ok(P.estimateText(portrait, { tracks: new Set(['video']), arrangement: 'separate' }, 'balanced', null).startsWith('最高 810 × 1440 · 30 帧'));
  });
  check(A6, '自定义大小：建议范围、下限与上限内体积', () => {
    assert.strictEqual(P.customGuidance(info, merged), '建议 17.8–194.3 MB · 最小值按“极小”档预算计算');
    assert.strictEqual(P.validationMessage(info, merged, 'custom', '1', 'a'), '视频上限请输入 17.8–100000 MB，不应低于“极小”档的体积预算。');
    assert.strictEqual(P.estimateText(info, merged, 'custom', 20), '最高 530 × 330 · 30 帧 · 每个视频 ≤ 20.0 MB');
    assert.ok(P.fileBytesFor('mergedVideo', info, merged, 'custom', 20) <= 20e6);
  });
  check(A6, '名称与内容校验文案', () => {
    assert.strictEqual(P.validationMessage(info, merged, 'balanced', '20', '.发布会/草案'), '名称不能以句点开头、包含 / 或 :，或超过 180 字节。');
    assert.strictEqual(P.validationMessage(info, { tracks: new Set(), arrangement: 'merged' }, 'balanced', '20', 'a'), '请选择已录制的内容。');
    assert.strictEqual(P.validationMessage(info, { tracks: new Set(['voice']), arrangement: 'merged' }, 'balanced', '20', 'a'), '请选择已录制的内容。');
    assert.strictEqual(P.validateName('  片段.MP4 ', '录屏'), '片段');
  });
  check(A6, '合并与分轨生成的文件组合', () => {
    const all = new Set(['video', 'systemAudio', 'voice']);
    assert.deepStrictEqual([...P.exportKinds({ tracks: all, arrangement: 'merged' })], ['mergedVideo']);
    assert.deepStrictEqual([...P.exportKinds({ tracks: all, arrangement: 'separate' })], ['video', 'systemAudio', 'voice']);
    assert.deepStrictEqual([...P.exportKinds({ tracks: new Set(['systemAudio', 'voice']), arrangement: 'merged' })], ['mixedAudio']);
    assert.deepStrictEqual([...P.exportKinds({ tracks: new Set(['systemAudio']), arrangement: 'merged' })], ['systemAudio']);
  });
  check(A6, '文件命名与重复导出不覆盖', () => {
    const stem = 'Snap 录屏 2026-09-28 20.31.07';
    const existing = new Set();
    const first = P.fileNamesFor(stem, ['video', 'systemAudio', 'voice'], existing);
    first.forEach((n) => existing.add(n));
    assert.deepStrictEqual([...first], ['Snap 视频 2026-09-28 20.31.07.mp4', 'Snap 电脑声音 2026-09-28 20.31.07.m4a', 'Snap 人声 2026-09-28 20.31.07.m4a']);
    assert.deepStrictEqual([...P.fileNamesFor(stem, ['video', 'systemAudio', 'voice'], existing)], ['Snap 视频 2026-09-28 20.31.07 (2).mp4', 'Snap 电脑声音 2026-09-28 20.31.07 (2).m4a', 'Snap 人声 2026-09-28 20.31.07 (2).m4a']);
    assert.deepStrictEqual([...P.fileNamesFor('发布会', ['video', 'voice'], new Set())], ['发布会 - 视频.mp4', '发布会 - 人声.m4a']);
    assert.deepStrictEqual([...P.fileNamesFor(stem, ['mixedAudio'], new Set())], ['Snap 声音 2026-09-28 20.31.07.m4a']);
  });
}

const A7 = 'A7 规格文字与样式表一致';
// 取“规格”某一节（按 section id）里某一行的文字；行头是 <th scope="row">，同名行在别的表里也有，所以按节限定
const specSection = (id) => {
  const m = new RegExp(`<section class="sheet-spec" id="${id}"[\\s\\S]*?</section>`).exec(html);
  if (!m) throw new Error(`页面没有规格一节 #${id}`);
  return m[0];
};
const specRow = (id, name) => {
  const m = new RegExp(`<th scope="row">${name}</th>((?:<td[^>]*>[\\s\\S]*?</td>)+)</tr>`).exec(specSection(id));
  if (!m) throw new Error(`#${id} 的表里没有“${name}”这一行`);
  return m[1].replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim();
};
check(A7, '色卡色值与样式变量一致', () => {
  const map = {
    '铝': '--alu', '铝亮': '--alu-hi', '铝暗': '--alu-lo', '刻线': '--groove',
    '石墨': '--graphite', '次石墨': '--ink-2', '刻字': '--engrave', '禁用': '--disabled',
    '窗': '--window', '读数': '--readout', '暗读数': '--readout-dim',
    '信号橙': '--signal', '指示灯 · 亮': '--led-on', '指示灯 · 灭': '--led-off', '警示': '--warn', '完成': '--ok'
  };
  const cards = [...html.matchAll(/<figure class="swatch"><span class="swatch-color[^"]*" style="--c:(#[0-9A-Fa-f]{6})"><\/span><figcaption><b>([^<]+)<\/b><code>(#[0-9A-Fa-f]{6})<\/code>/g)];
  const problems = [];
  for (const [, chip, name, code] of cards) {
    if (!map[name]) { problems.push(`未登记的色卡 ${name}`); continue; }
    const value = token(map[name]).toLowerCase();
    if (chip.toLowerCase() !== value || code.toLowerCase() !== value) problems.push(`${name}：色卡 ${chip} / 标注 ${code} / 样式 ${value}`);
  }
  assert.deepStrictEqual(problems, []);
  assert.strictEqual(cards.length, Object.keys(map).length, '色卡数量');
  return `${cards.length} 张色卡`;
});
function fontOf(selector) {
  let size;
  let lh;
  for (const r of rules) {
    if (!r.selectors.includes(selector)) continue;
    const f = r.decls.font && /(\d+(?:\.\d+)?)px\/(\d+(?:\.\d+)?)(px)?/.exec(r.decls.font);
    if (f && size === undefined) { size = Number(f[1]); lh = f[3] ? Number(f[2]) : Number(f[2]) * size; }
    if (r.decls['font-size'] && size === undefined) size = parseFloat(r.decls['font-size']);
    if (r.decls['line-height'] && lh === undefined) {
      const v = r.decls['line-height'];
      lh = v.endsWith('px') ? parseFloat(v) : parseFloat(v) * size;
    }
  }
  return { size, lh };
}
check(A7, '字号表与界面实际用到的样式一致', () => {
  // 字号表的每一层 → 样片里真正使用这一层的选择器
  const users = {
    '倒计时': ['.countdown-num'], '读数': ['.hud-time', '.duration'], '铭牌': ['.plate-name'], '标题': ['.export-head h4'],
    '键面': ['.key-rec', '.key-dark'], '模块刻字': ['.module-label', '.xlabel', '.field-label'],
    '正文': ['.ch-title', '.row-title', '.key-small'], '说明': ['.ch-sub', '.row-sub'], '静态数字': ['.ratio-label'],
    '读数正文': ['.estimate', '.saved-list'], '键帽': ['kbd']
  };
  const table = /<table class="spec-table type-table">([\s\S]*?)<\/table>/.exec(html)[1];
  const rows = [...table.matchAll(/<th scope="row">([^<]+)<\/th><td>[^<]*<\/td><td class="num">([\d.]+) \/ ([\d.]+)<\/td>/g)];
  assert.deepStrictEqual(rows.map((r) => r[1]), Object.keys(users), '字号表的行');
  const problems = [];
  for (const [, name, size, lh] of rows) {
    for (const sel of users[name]) {
      const f = fontOf(sel);
      if (f.size !== Number(size) || f.lh !== Number(lh)) problems.push(`${name} ${size}/${lh}：${sel} 为 ${f.size}/${f.lh}`);
    }
  }
  assert.deepStrictEqual(problems, []);
  return `${rows.length} 层`;
});
check(A7, '尺寸表与圆角和样式一致', () => {
  const problems = [];
  const expect = (row, phrase, pairs) => {
    if (!specRow('spec-space', row).includes(phrase)) problems.push(`尺寸表“${row}”没有写“${phrase}”`);
    for (const [sel, prop, value] of pairs) {
      let actual;
      try { actual = decl(sel, prop); } catch (error) { problems.push(error.message); continue; }
      if (!actual.split(' ').includes(value) && actual !== value) problems.push(`${phrase}：${sel} { ${prop}: ${actual} }`);
    }
  };
  expect('主面板', '宽 560', [['.mock-window', 'width', '560px']]);
  expect('主面板', '内边距 24', [['.setup-body', 'padding', '24px']]);
  expect('主面板', '标题栏 44', [['.titlebar', 'height', '44px']]);
  expect('主面板', '铭牌 40', [['.plate', 'height', '40px']]);
  expect('模块', '刻字 14 高、下距 10', [['.module-label', 'font', '500 11px/14px var(--sans)'], ['.module-label', 'margin', '0 0 10px']]);
  expect('模块', '模块上留 14、下留 16', [['.module', 'padding', '14px 0 16px']]);
  expect('模块', '模块间刻线 2（暗 1 + 亮 1）', [['.module + .module', 'border-top', 'var(--groove-line)'], ['.module + .module', 'box-shadow', 'var(--groove-hi)'],
    [':root', '--groove-line', '1px solid rgba(0, 0, 0, 0.14)'], [':root', '--groove-hi', 'inset 0 1px 0 rgba(255, 255, 255, 0.55)']]);
  expect('来源', '旋钮 56', [['.knob', 'width', '56px'], ['.knob', 'height', '56px']]);
  expect('来源', '三个挡位各 20 高', [['.stop', 'height', '20px']]);
  expect('来源', '细节区宽 338', [['.source-grid', 'grid-template-columns', '158px minmax(0, 1fr)'], ['.source-grid', 'gap', '16px']]);
  if (560 - 24 * 2 - 158 - 16 !== 338) problems.push('细节区宽度推算不符');
  expect('通道', '四列等宽 · 列间 8', [['.channels', 'grid-template-columns', 'repeat(4, minmax(0, 1fr))'], ['.channels', 'gap', '8px']]);
  expect('通道', '拨杆槽 36 × 20、钮 16 × 14', [['.switch', 'width', '36px'], ['.switch', 'height', '20px'], ['.switch::after', 'width', '16px'], ['.switch::after', 'height', '14px']]);
  // 拨杆：槽与钮同心（槽圆角 = 钮圆角 + 间隙），四周间隙相等，行程 = 槽宽 − 2 × 间隙 − 钮宽
  {
    const px = (v) => parseFloat(v);
    const r = { '--r-3': 3, '--r-6': 6 };
    const slotR = r[/var\((--r-\d+)\)/.exec(decl('.switch', 'border-radius'))[1]];
    const knobR = r[/var\((--r-\d+)\)/.exec(decl('.switch::after', 'border-radius'))[1]];
    const gapX = px(decl('.switch::after', 'left'));
    const gapY = px(decl('.switch::after', 'top'));
    const gapBottom = px(decl('.switch', 'height')) - gapY - px(decl('.switch::after', 'height'));
    const travel = px(decl('.switch', 'width')) - 2 * gapX - px(decl('.switch::after', 'width'));
    if (!(gapX === gapY && gapY === gapBottom)) problems.push(`拨杆四周间隙不等：左 ${gapX}、上 ${gapY}、下 ${gapBottom}`);
    if (slotR !== knobR + gapY) problems.push(`拨杆不同心：槽圆角 ${slotR}，钮圆角 ${knobR} + 间隙 ${gapY}`);
    const moved = /translateX\((\d+)px\)/.exec(decl('.switch[aria-checked="true"]::after', 'transform'));
    if (!moved || Number(moved[1]) !== travel) problems.push(`拨杆行程应为 ${travel}`);
    if (!html.includes(`行程 ${travel}`) || !html.includes('四周留 3，与槽同心')) problems.push('控件说明没有写拨杆行程与同心');
  }
  expect('通道', '指示灯 6', [['.switch::before', 'width', '6px'], ['.led', 'width', '6px']]);
  expect('键', '录制键 44 · 深色大键 44 · 普通键 32 · 小键 24 · 键帽 18',
    [['.key-rec', 'height', '44px'], ['.key-dark', 'height', '44px'], ['.key', 'height', '32px'], ['.key-small', 'height', '24px'], ['kbd', 'height', '18px']]);
  expect('浮窗', '倒计时 174 × 174', [['.countdown', 'width', '174px'], ['.countdown', 'height', '174px']]);
  expect('浮窗', '控制条 274 × 54，距顶 18', [['.hud', 'width', '274px'], ['.hud', 'height', '54px'], ['.hud', 'top', '18px']]);
  expect('浮窗', '人像样式面板宽 354', [['.sheet', 'width', '354px']]);
  // 圆角：3 小键、键帽、显示窗、拨杆钮；6 普通键、通道槽、拨杆槽；10 录制键、深色大键、浮窗面板
  const radius = [['.key-small', 'var(--r-3)'], ['kbd', 'var(--r-3)'], ['.hud-display', 'var(--r-3)'], ['.readout', 'var(--r-3)'], ['.switch::after', 'var(--r-3)'],
    ['.key', 'var(--r-6)'], ['.channel', 'var(--r-6)'], ['.switch', 'var(--r-6)'],
    ['.key-rec', 'var(--r-10)'], ['.key-dark', 'var(--r-10)'], ['.hud', 'var(--r-10)'], ['.countdown', 'var(--r-10)'], ['.sheet', 'var(--r-10)']];
  for (const [sel, value] of radius) if (decl(sel, 'border-radius') !== value) problems.push(`圆角：${sel} 为 ${decl(sel, 'border-radius')}`);
  for (const [name, px] of [['--r-3', '3px'], ['--r-6', '6px'], ['--r-10', '10px']]) if (decl(':root', name) !== px) problems.push(`${name} 不是 ${px}`);
  // 倒计时表盘：132 圆盘，一圈 60 格刻度（每格 6°）
  if (decl('.dial', 'width') !== '132px' || !/transparent 0\.8deg 6deg/.test(decl('.dial::before', 'background'))) problems.push('表盘尺寸或刻度间隔不符');
  assert.deepStrictEqual(problems, []);
});
check(A7, '动效表、旋钮角度与“减少动态效果”一致', () => {
  const problems = [];
  const need = (row, phrase) => { if (!specRow('spec-motion', row).includes(phrase)) problems.push(`动效表“${row}”没有写“${phrase}”`); };
  const is = (label, actual, expected) => { if (actual !== expected) problems.push(`${label}：${actual}，应为 ${expected}`); };
  need('按键', '80ms'); is('按键时长', decl(':root', '--t-key'), '80ms');
  need('拨杆、互锁键、滑块', '160ms · cubic-bezier(.4, 0, .2, 1)');
  is('平移时长', decl(':root', '--t-slide'), '160ms'); is('平移曲线', decl(':root', '--ease-slide'), 'cubic-bezier(0.4, 0, 0.2, 1)');
  need('旋钮', '220ms · cubic-bezier(.3, 1.4, .5, 1)');
  is('旋钮时长', decl(':root', '--t-knob'), '220ms'); is('旋钮曲线', decl(':root', '--ease-knob'), 'cubic-bezier(0.3, 1.4, 0.5, 1)');
  is('旋钮转动', decl('.knob-pointer', 'transition'), 'transform var(--t-knob) var(--ease-knob)');
  const angles = { browser: '-29deg', display: '0deg', region: '29deg' };
  for (const [mode, deg] of Object.entries(angles)) is(`旋钮 ${mode} 挡`, decl(`.setup-window[data-mode="${mode}"] .knob-pointer`, '--angle'), deg);
  if (!html.includes('三挡分别指向 −29°、0°、29°')) problems.push('控件说明没有写三挡角度');
  need('指示灯', '录制暂停时 1.2 秒慢闪'); is('暂停慢闪', decl('.hud[data-paused="true"] .hud-led', 'animation'), 'blink 1.2s steps(1) infinite');
  need('倒计时', '指针 1 秒线性扫一圈'); is('指针扫动', decl('.dial-needle.is-run', 'animation'), 'sweep 1s linear forwards');
  need('导出中', '1.2s 循环'); is('走马', decl('.chaser i', 'animation'), 'chase 1.2s steps(1) infinite');
  const lamps = /<span class="chaser"[^>]*>((?:<i><\/i>)+)<\/span>/.exec(html);
  is('走马灯数', lamps ? lamps[1].split('<i>').length - 1 : 0, 10);
  // 减少动态效果：这几项在媒体查询里被关掉
  const reduced = /@media \(prefers-reduced-motion: reduce\) \{([\s\S]*)\}\s*$/.exec(cssNoComments);
  if (!reduced) problems.push('缺少 prefers-reduced-motion 段落');
  else {
    const block = reduced[1];
    for (const sel of ['.hud[data-paused="true"] .hud-led', '.chaser i', '.dial-needle.is-run']) {
      if (!new RegExp(`${sel.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}[^{]*\\{[^}]*animation: none !important`).test(block)) problems.push(`减少动态效果未关闭 ${sel}`);
    }
    if (!/transition-duration: 1ms !important/.test(block)) problems.push('减少动态效果未取消过渡（旋钮回弹）');
  }
  assert.ok(/if \(reduceMotion\) return;/.test(js), '脚本在减少动态效果时应跳过指针动画');
  assert.deepStrictEqual(problems, []);
});

/* ================= B 模拟交互 ================= */
const { doc, state } = createDocument(html, { stageW: 1000, stageH: 625 });
const clock = createClock();
const pageContext = {
  document: doc, console, performance: { now: clock.now },
  setTimeout: clock.setTimeout, clearTimeout: clock.clear, setInterval: clock.setInterval, clearInterval: clock.clear,
  matchMedia: () => ({ matches: false }), addEventListener() {}, removeEventListener() {}
};
pageContext.window = pageContext;
pageContext.globalThis = pageContext;
vm.createContext(pageContext);
let pageLoaded = true;
try { vm.runInContext(js, pageContext, { filename: 'instrument.js' }); } catch (error) { pageLoaded = false; results.push({ group: 'B 模拟交互', name: '页面脚本加载', ok: false, detail: error.message }); }

const $ = (sel) => { const n = doc.querySelector(sel); if (!n) throw new Error(`找不到元素 ${sel}`); return n; };
const click = (sel) => $(sel).click();
const text = (sel) => $(sel).textContent.trim();
const attr = (sel, name) => $(sel).getAttribute(name);
const press = (key, target) => (target ? $(target) : doc.body).dispatchEvent(evt('keydown', { key }));
const typeInto = (sel, value) => { const n = $(sel); n.value = value; n.dispatchEvent(evt('input')); };
const savedNames = () => $('#exp-saved-list').querySelectorAll('.file').map((n) => n.textContent);
// 导出内容锁定键：勾选状态与“按下”外观（is-on）要一致
const trackKeys = () => ['video', 'systemAudio', 'voice'].map((t) => {
  const input = $(`input[data-track="${t}"]`);
  const label = $(`label[data-track-label="${t}"]`);
  return `${t}:${input.checked ? '勾' : '空'}${label.classList.contains('is-on') ? '按下' : '弹起'}`;
});
const assertKeysInSync = () => {
  for (const item of trackKeys()) assert.ok(/勾按下|空弹起/.test(item), `锁定键外观与勾选不一致：${item}`);
};

if (pageLoaded) {
  const B1 = 'B1 初始状态与默认值';
  check(B1, '录前默认：电脑声音开、人声关、摄像头关、录制鼠标开、来源为任意窗口（旋钮指向第一挡）', () => {
    assert.strictEqual(attr('[data-toggle="systemAudio"]', 'aria-checked'), 'true');
    assert.strictEqual(attr('[data-toggle="mic"]', 'aria-checked'), 'false');
    assert.strictEqual(attr('[data-toggle="camera"]', 'aria-checked'), 'false');
    assert.strictEqual(attr('[data-toggle="mouse"]', 'aria-checked'), 'true');
    assert.strictEqual(attr('.source-tab[data-mode="browser"]', 'aria-checked'), 'true');
    assert.strictEqual(attr('#setup-window', 'data-mode'), 'browser');
  });
  check(B1, '示例导出页：高清、合并、未录人声不可勾选、默认名称，滑块停在“高清”', () => {
    assert.strictEqual(attr('[data-seg="quality"] [data-value="maximum"]', 'aria-checked'), 'true');
    assert.strictEqual(attr('[data-seg="quality"]', 'data-value'), 'maximum');
    assert.strictEqual(attr('[data-seg="arrangement"] [data-value="merged"]', 'aria-checked'), 'true');
    assert.ok($('input[data-track="voice"]').disabled);
    assert.ok($('label[data-track-label="voice"]').classList.contains('is-disabled'));
    assert.strictEqual($('label[data-track-label="voice"]').title, '未录制人声');
    assertKeysInSync();
    assert.strictEqual($('#exp-name').value, 'Snap 录屏 2026-09-28 20.31.07');
    assert.strictEqual(text('#exp-estimate'), '2560 × 1600 · 30 帧 · 视频约 194.3 MB');
    return trackKeys().join('、');
  });

  const B2 = 'B2 来源选择与录前设置';
  check(B2, '来源旋钮：点挡位与方向键都会切换，面板的 data-mode 跟着变（驱动指针角度）', () => {
    click('.source-tab[data-mode="display"]');
    assert.strictEqual(attr('#setup-window', 'data-mode'), 'display');
    assert.ok(!$('.source-pane[data-pane="display"]').hidden && $('.source-pane[data-pane="browser"]').hidden);
    press('ArrowLeft', '.source-tab[data-mode="display"]');
    assert.strictEqual(attr('#setup-window', 'data-mode'), 'browser');
    assert.strictEqual(doc.activeElement, $('.source-tab[data-mode="browser"]'));
    press('End', '.source-tab[data-mode="browser"]');
    assert.strictEqual(attr('#setup-window', 'data-mode'), 'region');
    click('.source-tab[data-mode="browser"]');
  });
  check(B2, '摄像头：准备中 → 就绪 → 出现人像样式与示意预览', () => {
    click('[data-toggle="camera"]');
    assert.strictEqual(text('#camera-sub'), '正在准备摄像头…');
    clock.advance(700);
    assert.strictEqual(text('#camera-sub'), '人像叠入成片 · 右下角');
    assert.ok(!$('#camera-style').hidden);
    assert.strictEqual(attr('#stage', 'data-camera'), 'on');
    assert.strictEqual($('#stage-cam').style.width, '99px', '边长应为窗口短边的 24%');
  });
  check(B2, '人像样式面板：位置、形状、方向键、Esc 关闭并还原焦点', () => {
    click('#camera-style');
    assert.ok(!$('#camera-sheet').hidden);
    assert.strictEqual(doc.activeElement, $('.pos[data-pos="bottomRight"]'));
    click('.pos[data-pos="topLeft"]');
    assert.strictEqual(text('#camera-sub'), '人像叠入成片 · 左上角');
    click('[data-seg="shape"] [data-value="circle"]');
    assert.strictEqual(attr('#stage-cam', 'data-shape'), 'circle');
    click('[data-seg="portrait"] [data-value="soft"]');
    press('ArrowRight', '[data-seg="portrait"] [data-value="soft"]');
    assert.strictEqual(text('#portrait-sub'), '保留原始画面，不做修饰');
    press('Escape');
    assert.ok($('#camera-sheet').hidden);
    assert.strictEqual(doc.activeElement, $('#camera-style'));
  });
  check(B2, '局部录像：比例角标、聚焦蒙版、自定义与方角的禁用规则、锁定提示', () => {
    click('[data-toggle="mic"]');
    click('.source-tab[data-mode="region"]');
    click('.ratio[data-ratio="9:16"]');
    assert.strictEqual(text('#region-badge'), '9:16  ·  拖动框内移动 · ⌘E 锁定');
    click('[data-toggle="focusMask"]');
    assert.ok(!$('[data-seg="focusCorner"]').hidden);
    assert.strictEqual(text('#region-badge'), '9:16  ·  拖动内框聚焦 · ⌘E 锁定');
    click('.ratio[data-ratio="custom"]');
    assert.ok($('[data-toggle="focusMask"]').disabled);
    assert.strictEqual(text('#focus-sub'), '选择固定比例后可用');
    click('[data-seg="regionCorner"] [data-value="square"]');
    assert.ok($('[data-toggle="vignette"]').disabled);
    click('[data-review="region:lock"]');
    assert.strictEqual(text('#region-lock-hint'), '浮层已锁定 · ⌘E 调整');
    click('[data-review="region:lock"]');
    click('.ratio[data-ratio="16:9"]');
    click('[data-seg="regionCorner"] [data-value="rounded"]');
  });

  const B3 = 'B3 录制中控制';
  check(B3, '倒计时 3、2、1 后开始录制，主面板收起，选区自动锁定并转为录制态（刻度转橙）', () => {
    click('#start-recording');
    assert.strictEqual(attr('#stage', 'data-phase'), 'countdown');
    assert.strictEqual(text('#countdown-num'), '3');
    assert.ok($('#countdown-ring').classList.contains('is-run'), '指针应开始扫动');
    assert.ok(!$('#setup-veil').hidden);
    assert.strictEqual(attr('#stage-region', 'data-locked'), 'true');
    clock.advance(1000); assert.strictEqual(text('#countdown-num'), '2');
    clock.advance(1000); assert.strictEqual(text('#countdown-num'), '1');
    clock.advance(1000);
    assert.strictEqual(attr('#stage', 'data-phase'), 'recording');
    assert.strictEqual(attr('#stage-region', 'data-live'), 'true');
  });
  check(B3, '暂停时计时停住并显示“已暂停”（控制条标记暂停，灯改慢闪），继续后接着累计', () => {
    clock.advance(5000);
    assert.strictEqual(text('#hud-time'), '00:05');
    click('#hud-pause');
    assert.strictEqual(text('#hud-time'), '已暂停');
    assert.strictEqual(attr('#stage-hud', 'data-paused'), 'true');
    clock.advance(3000);
    click('#hud-pause');
    assert.strictEqual(attr('#stage-hud', 'data-paused'), 'false');
    clock.advance(2000);
    assert.strictEqual(text('#hud-time'), '00:07');
  });
  check(B3, 'Esc 结束：释放摄像头、主面板转到导出页、先整理再显示', () => {
    press('Escape');
    assert.strictEqual(attr('#stage', 'data-phase'), 'idle');
    assert.strictEqual(attr('[data-toggle="camera"]', 'aria-checked'), 'false');
    assert.strictEqual(text('#setup-veil-title'), '主面板正在显示导出页');
    assert.strictEqual(text('#exp-progress-text'), '正在整理录制…');
    clock.advance(700);
    assert.strictEqual(attr('#export-window', 'data-view'), 'choose');
    assert.strictEqual(text('#exp-duration'), '00:07');
    assert.strictEqual(doc.activeElement, $('#exp-name'));
  });

  const B4 = 'B4 命名与导出';
  check(B4, '默认勾选全部已录内容且三颗锁定键都按下；有人声时默认分轨', () => {
    for (const t of ['video', 'systemAudio', 'voice']) assert.ok($(`input[data-track="${t}"]`).checked && !$(`input[data-track="${t}"]`).disabled);
    assertKeysInSync();
    assert.strictEqual(attr('[data-seg="arrangement"] [data-value="separate"]', 'aria-checked'), 'true');
  });
  check(B4, '取消勾选后锁定键弹起，再勾上又按下', () => {
    click('input[data-track="systemAudio"]');
    assert.ok(!$('label[data-track-label="systemAudio"]').classList.contains('is-on'));
    assertKeysInSync();
    click('input[data-track="systemAudio"]');
    assertKeysInSync();
  });
  check(B4, '保存后列出分轨文件，按钮改为“再导出一份”与“完成”', () => {
    click('#exp-save');
    assert.strictEqual(text('#exp-progress-text'), '正在导出…');
    clock.advance(2200);
    const names = savedNames();
    assert.strictEqual(names.length, 3);
    assert.ok(names[0].startsWith('Snap 视频 ') && names[1].startsWith('Snap 电脑声音 ') && names[2].startsWith('Snap 人声 '));
    assert.strictEqual(text('#exp-save-label'), '再导出一份');
    assert.strictEqual(text('#exp-discard'), '完成');
  });
  check(B4, '再导出一份不覆盖已有文件，取消导出不新增文件', () => {
    click('#exp-save'); clock.advance(2200);
    assert.ok(savedNames().slice(3).every((n) => n.includes(' (2).')));
    click('#exp-save'); click('#exp-cancel');
    assert.strictEqual(text('#exp-cancel'), '正在取消…');
    clock.advance(600);
    assert.strictEqual(savedNames().length, 6);
  });
  check(B4, '重新录制直接倒计时并恢复摄像头；未保存时“放弃此次录制”回到录前设置', () => {
    click('#exp-restart');
    assert.strictEqual(attr('#stage', 'data-phase'), 'countdown');
    assert.strictEqual(attr('[data-toggle="camera"]', 'aria-checked'), 'true');
    clock.advance(4500);
    click('#hud-stop');
    clock.advance(700);
    assert.strictEqual(text('#exp-discard'), '放弃此次录制');
    click('#exp-discard');
    assert.ok(!$('#export-veil').hidden && $('#setup-veil').hidden);
  });
  check(B4, '名称有误与自定义上限过小时不能保存；滑块移到“自定义”；上限内的体积不超过上限', () => {
    click('#export-demo');
    click('[data-xreview="show:name-error"]');
    assert.ok(!$('#exp-error').hidden && $('#exp-save').disabled);
    typeInto('#exp-name', '发布会');
    click('[data-xreview="show:custom"]');
    assert.strictEqual(attr('[data-seg="quality"]', 'data-value'), 'custom');
    assert.strictEqual($('#exp-custom-mb').value, '194.3');
    typeInto('#exp-custom-mb', '1');
    assert.ok($('#exp-save').disabled);
    typeInto('#exp-custom-mb', '20');
    click('#exp-save'); clock.advance(2200);
    assert.strictEqual(savedNames()[0], '发布会.mp4');
    assert.strictEqual($('#exp-saved-list').querySelector('.size').textContent, '19.2 MB');
  });
  check(B4, '五挡滑块：方向键逐挡移动，滑块位置跟随', () => {
    click('[data-xreview="rec:vav"]');
    click('[data-seg="quality"] [data-value="maximum"]');
    assert.strictEqual(attr('[data-seg="quality"]', 'data-value'), 'maximum');
    press('ArrowRight', '[data-seg="quality"] [data-value="maximum"]');
    press('ArrowRight', '[data-seg="quality"] [data-value="balanced"]');
    assert.strictEqual(attr('[data-seg="quality"]', 'data-value'), 'compact');
    assert.strictEqual(attr('[data-seg="quality"] [data-value="compact"]', 'aria-checked'), 'true');
  });
  check(B4, '纯音频合并只出一个“声音”文件，视频键弹起并收起视频大小', () => {
    click('[data-xreview="show:audio-only"]');
    assert.ok($('#exp-size-row').hidden);
    assert.ok(!$('label[data-track-label="video"]').classList.contains('is-on'));
    assertKeysInSync();
    click('#exp-save'); clock.advance(2200);
    assert.deepStrictEqual(savedNames(), ['Snap 声音 2026-09-28 20.31.07.m4a']);
  });
  check(B4, '未保存就关窗口时提示；Esc 等同“继续导出”', () => {
    click('[data-xreview="rec:vav"]');
    click('[data-xreview="show:close-alert"]');
    assert.ok(!$('#exp-alert').hidden);
    assert.strictEqual(doc.activeElement, $('#alert-continue'));
    press('Escape');
    assert.ok($('#exp-alert').hidden);
  });

  const B5 = 'B5 边缘状态与收尾';
  check(B5, '窗口读取中或已关闭时不能开始，重新选择后恢复', () => {
    click('[data-review="browser:loading"]');
    assert.ok($('#start-recording').disabled);
    click('[data-review="browser:closed"]');
    assert.ok(!$('#browser-note').hidden && $('#window-select').selectedIndex === -1 && $('#start-recording').disabled);
    const select = $('#window-select');
    select.value = 'chrome';
    select.dispatchEvent(evt('change'));
    assert.ok(!$('#start-recording').disabled);
    assert.strictEqual(text('#stage-window-title'), '设计规范 v2');
  });
  check(B5, '权限未开启时开关不打开并给出提示', () => {
    click('[data-review="perm:mic"]');
    click('[data-toggle="mic"]');
    assert.strictEqual(text('#mic-sub'), '麦克风权限未开启');
    assert.ok(!$('#mic-settings').hidden);
    click('[data-review="perm:camera"]');
    click('[data-toggle="camera"]'); clock.advance(700);
    assert.strictEqual(text('#camera-sub'), '摄像头权限未开启');
    assert.strictEqual(attr('[data-toggle="camera"]', 'aria-checked'), 'false');
    click('[data-review="perm:ok"]');
  });
  check(B5, '点击扩散会自动移除，且没有残留的循环计时器', () => {
    $('#stage').dispatchEvent(evt('pointerdown', { clientX: 120, clientY: 80 }));
    assert.strictEqual($('#stage').querySelectorAll('.ripple').length, 1);
    clock.advance(1000);
    assert.strictEqual($('#stage').querySelectorAll('.ripple').length, 0);
    assert.strictEqual(clock.pendingIntervals(), 0);
    return `页面滚动目标：${[...new Set(state.scrolled)].join('、')}`;
  });
}

/* ================= 输出 ================= */
let failed = 0;
let currentGroup = '';
for (const r of results) {
  if (r.group !== currentGroup) { currentGroup = r.group; console.log(`\n${currentGroup}`); }
  if (!r.ok) failed++;
  console.log(`  ${r.ok ? '通过' : '失败'}  ${r.name}${r.detail ? `（${r.detail}）` : ''}`);
}
console.log(`\n共 ${results.length} 项，${failed ? `${failed} 项失败` : '全部通过'}。`);
console.log('\n以上都是离线检查：A 为静态检查，B 为最小 DOM 里的模拟交互。以下只能在真实浏览器里验收：');
[
  '字体实际渲染：DIN Alternate、SF Mono 与苹方的回退（非 macOS 或 Chrome 下 SF Mono 可能落到 Menlo）。',
  '点阵遮罩：18 号计时与 72 号倒计时的清晰度，不支持 mask 时是否正常退回普通等宽字。',
  '材质：拉丝纹、刻线、键的高光与侧面、显示窗内凹、选区刻度尺在深浅画面上的可见度。',
  '版式：主面板四路通道、旋钮与挡位在 1120 与 760 断点下的排布，人像样式面板的高度和滚动。',
  '动效：旋钮回弹、拨杆与滑块平移、控制条暂停慢闪、导出走马、倒计时指针扫动，以及“减少动态效果”模式。',
  '交互手感：键盘焦点环、inert 遮挡、页面滚动定位与 Esc 的真实表现。',
  '对比度按色值计算，叠加拉丝纹与渐变后的实际观感需要目测。'
].forEach((item, i) => console.log(`  ${i + 1}. ${item}`));
process.exitCode = failed ? 1 : 0;
