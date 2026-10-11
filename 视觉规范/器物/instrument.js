/* 器物正式视觉规范 —— 样片交互（纯模拟）
 * 交互逻辑与方案一、二共用同一套产品规则（各自独立一份，互不依赖），只有页面结构与视觉不同。
 * 给“视频大小”滑块写入当前档位（驱动滑块位置），给导出内容按键写入按下状态；倒计时数字不做动画。
 * 不调用摄像头、麦克风、屏幕录制、存储或任何网络接口；“录制”“保存”只改变页面状态。
 * Planning 按软件现有 ExportPlanning / TimeFormatting 规则推算尺寸、体积与文件名，只用于样片里的数字。
 */
(function (root) {
  'use strict';

  /* ================= 纯逻辑（可在无页面环境下单独检查） ================= */
  const FRAME_RATE = 30;
  const MAX_CUSTOM_MB = 100000;
  const PRESETS = {
    maximum: { title: '高清', audio: 192000 },
    balanced: { title: '日常', audio: 128000 },
    compact: { title: '小巧', audio: 96000 },
    tiny: { title: '极小', audio: 64000 },
    custom: { title: '自定义', audio: 96000 }
  };
  const SOURCE_FRACTION = { maximum: 1, balanced: 0.5, compact: 0.2, tiny: 0.08, custom: 1 };
  const RESOLUTION_SCALE = { maximum: 1, balanced: 0.75, compact: 0.5, tiny: 0.25 };
  const TRACK_TITLES = { video: '视频', systemAudio: '电脑声音', voice: '人声' };
  const TRACK_ORDER = ['video', 'systemAudio', 'voice'];

  function pad2(n) { return String(n).padStart(2, '0'); }

  function formatDuration(seconds) {
    const total = Math.max(0, Math.floor(seconds));
    const h = Math.floor(total / 3600);
    const m = Math.floor((total % 3600) / 60);
    const s = total % 60;
    return h > 0 ? `${pad2(h)}:${pad2(m)}:${pad2(s)}` : `${pad2(m)}:${pad2(s)}`;
  }

  function outputStem(date) {
    const d = date || new Date();
    return `Snap 录屏 ${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())} ` +
      `${pad2(d.getHours())}.${pad2(d.getMinutes())}.${pad2(d.getSeconds())}`;
  }

  function sizeText(bytes) {
    return bytes >= 1e9 ? `${(bytes / 1e9).toFixed(2)} GB` : `${(bytes / 1e6).toFixed(1)} MB`;
  }

  function even(v) { const i = Math.max(2, Math.floor(v)); return i - (i % 2); }
  function evenSize(w, h) { return { w: even(w), h: even(h) }; }
  function fit(src, bounds, allowUpscale) {
    if (!(src.w > 0 && src.h > 0)) return { w: 0, h: 0 };
    const scale = Math.min(bounds.w / src.w, bounds.h / src.h);
    const s = allowUpscale ? scale : Math.min(scale, 1);
    return evenSize(src.w * s, src.h * s);
  }
  function bytesPerSecond(p) { return (p.videoBitrate + p.audioBitrate) / 8 * 1.02; }
  function byteCeiling(p, duration) { return Math.trunc(bytesPerSecond(p) * duration * 1.06 + 16384); }
  function fail(message) { const e = new Error(message); e.planning = true; return e; }

  // o: { size, duration, preset, customMB, hasSystemAudio, sourceVideoBitrate, sourceFrameRate, sourceBytes, includesCombinedVoice }
  function plan(o) {
    const src = o.size;
    if (!(Number.isFinite(o.duration) && o.duration > 0 && src && src.w > 0 && src.h > 0)) {
      throw fail('录制时长或画面尺寸无效。');
    }
    const hasAudio = !!(o.hasSystemAudio || o.includesCombinedVoice);
    const audioRate = hasAudio ? PRESETS[o.preset].audio : 0;
    const nativeBitrate = Math.max(1e6, Math.min(32e6, Math.trunc(src.w * src.h * 5.8)));
    let bounds;
    let bitrate;
    let limit = null;
    switch (o.preset) {
      case 'maximum':
      case 'balanced':
      case 'compact':
      case 'tiny': {
        const scale = RESOLUTION_SCALE[o.preset];
        bounds = evenSize(src.w * scale, src.h * scale);
        bitrate = Math.max(80000, Math.trunc(nativeBitrate * SOURCE_FRACTION[o.preset]));
        break;
      }
      case 'custom': {
        const rec = customRecommendation(o);
        const mb = o.customMB;
        if (!(typeof mb === 'number' && Number.isFinite(mb) && mb >= rec.minimum && mb <= MAX_CUSTOM_MB)) {
          throw fail(`视频上限请输入 ${rec.minimum.toFixed(1)}–100000 MB，不应低于“极小”档的体积预算。`);
        }
        limit = Math.trunc(mb * 1e6);
        const mixReserve = o.includesCombinedVoice
          ? (o.hasSystemAudio ? 16384 : audioRate / 8 * o.duration + 16384) : 0;
        if (o.sourceBytes != null && o.sourceFrameRate > 0 && o.sourceFrameRate <= FRAME_RATE + 0.001 &&
            o.sourceBytes + mixReserve <= limit) {
          return {
            size: { w: src.w, h: src.h }, frameRate: FRAME_RATE,
            videoBitrate: Math.trunc(o.sourceVideoBitrate || 1e6), audioBitrate: audioRate,
            byteLimit: limit, preservesSource: true
          };
        }
        const budget = (limit * 0.94 - 16384) * 8 / o.duration - audioRate;
        if (budget < 80000) throw fail('这个体积不足以保存完整录制，请提高大小上限。');
        bitrate = Math.min(32e6, Math.trunc(budget));
        const scale = Math.min(1, Math.max(0.125, Math.sqrt(bitrate / nativeBitrate)));
        bounds = evenSize(src.w * scale, src.h * scale);
        break;
      }
      default:
        throw fail('未知的视频大小档位。');
    }
    const size = fit(src, bounds, false);
    if (Number.isFinite(o.sourceVideoBitrate) && o.sourceVideoBitrate > 0) {
      bitrate = Math.min(bitrate, Math.max(80000, Math.trunc(o.sourceVideoBitrate * SOURCE_FRACTION[o.preset])));
    }
    return {
      size: evenSize(size.w, size.h), frameRate: FRAME_RATE,
      videoBitrate: Math.max(80000, bitrate), audioBitrate: audioRate,
      byteLimit: limit, preservesSource: false
    };
  }

  function customRecommendation(o) {
    const tiny = plan({
      size: o.size, duration: o.duration, preset: 'tiny', hasSystemAudio: o.hasSystemAudio,
      sourceVideoBitrate: o.sourceVideoBitrate, includesCombinedVoice: o.includesCombinedVoice
    });
    const minimum = Math.max(0.1, Math.ceil(byteCeiling(tiny, o.duration) / 100000) / 10);
    if (minimum > MAX_CUSTOM_MB) throw fail('这段录制的“极小”档已超过可设置的大小上限。');
    const voiceBytes = o.includesCombinedVoice && !o.hasSystemAudio ? PRESETS.custom.audio / 8 * o.duration : 0;
    const sourceEstimate = Math.ceil(((o.sourceBytes || 0) + voiceBytes + 16384) / 100000) / 10;
    return { minimum, suggestedMaximum: Math.min(MAX_CUSTOM_MB, Math.max(minimum, sourceEstimate)) };
  }

  function selectionFlags(sel) {
    const video = sel.tracks.has('video');
    return {
      includesVideo: video,
      includesSystemInVideo: video && sel.tracks.has('systemAudio') && sel.arrangement !== 'separate',
      includesVoiceInVideo: video && sel.tracks.has('voice') && sel.arrangement === 'merged'
    };
  }

  function planFor(info, sel, preset, customMB) {
    const f = selectionFlags(sel);
    return plan({
      size: info.size, duration: info.duration, preset, customMB,
      hasSystemAudio: f.includesSystemInVideo, sourceVideoBitrate: info.sourceVideoBitrate,
      sourceFrameRate: info.sourceFrameRate, sourceBytes: info.sourceBytes,
      includesCombinedVoice: f.includesVoiceInVideo
    });
  }

  function recommendationFor(info, sel) {
    const f = selectionFlags(sel);
    return customRecommendation({
      size: info.size, duration: info.duration, hasSystemAudio: f.includesSystemInVideo,
      sourceVideoBitrate: info.sourceVideoBitrate, sourceBytes: info.sourceBytes,
      includesCombinedVoice: f.includesVoiceInVideo
    });
  }

  function estimateText(info, sel, preset, customMB) {
    const f = selectionFlags(sel);
    if (!f.includesVideo) return '';
    let p;
    try { p = planFor(info, sel, preset, customMB); } catch (e) { return ''; }
    const size = `${p.size.w} × ${p.size.h} · ${p.frameRate} 帧`;
    if (p.byteLimit != null) return `最高 ${size} · 每个视频 ≤ ${sizeText(p.byteLimit)}`;
    const estimate = bytesPerSecond(p) * info.duration;
    if (preset === 'maximum') {
      const voiceBytes = !f.includesSystemInVideo && f.includesVoiceInVideo ? p.audioBitrate / 8 * info.duration : 0;
      const upper = info.sourceBytes + voiceBytes;
      const lower = Math.min(upper, estimate);
      const text = upper - lower > 100000 ? `${sizeText(lower)}–${sizeText(upper)}` : sizeText(upper);
      return `${size} · 视频约 ${text}`;
    }
    return `最高 ${size} · 视频约 ${sizeText(estimate)}`;
  }

  function customGuidance(info, sel) {
    if (!selectionFlags(sel).includesVideo) return '';
    try {
      const r = recommendationFor(info, sel);
      return `建议 ${r.minimum.toFixed(1)}–${r.suggestedMaximum.toFixed(1)} MB · 最小值按“极小”档预算计算`;
    } catch (e) { return ''; }
  }

  function parseMegabytes(text) {
    const t = String(text == null ? '' : text);
    return /^[+-]?(\d+(\.\d*)?|\.\d+)([eE][+-]?\d+)?$/.test(t) ? Number(t) : null;
  }

  const CONTROL_CHARS = /[\u0000-\u001f\u007f-\u009f]/;
  function utf8Length(text) {
    let n = 0;
    for (const ch of text) {
      const c = ch.codePointAt(0);
      n += c < 0x80 ? 1 : c < 0x800 ? 2 : c < 0x10000 ? 3 : 4;
    }
    return n;
  }
  function validateName(input, fallback) {
    let name = String(input == null ? '' : input).trim();
    if (name.toLowerCase().endsWith('.mp4')) name = name.slice(0, -4);
    if (!name) name = fallback;
    if (name === '.' || name === '..' || name.startsWith('.') || name.includes('/') || name.includes(':') ||
        CONTROL_CHARS.test(name) || utf8Length(name) > 180) {
      throw fail('名称不能以句点开头、包含 / 或 :，或超过 180 字节。');
    }
    return name;
  }

  function validationMessage(info, sel, preset, customText, name) {
    try {
      validateName(name, '录屏');
      if (sel.tracks.size === 0 || Array.from(sel.tracks).some((t) => !info.available.has(t))) {
        throw fail('请选择已录制的内容。');
      }
      if (sel.tracks.has('video')) planFor(info, sel, preset, parseMegabytes(customText));
      return null;
    } catch (e) { return e.message; }
  }

  function exportKinds(sel) {
    if (sel.arrangement === 'merged') {
      if (sel.tracks.has('video')) return ['mergedVideo'];
      if (sel.tracks.has('systemAudio') && sel.tracks.has('voice')) return ['mixedAudio'];
    }
    return TRACK_ORDER.filter((t) => sel.tracks.has(t));
  }

  function sibling(stem, prefixes, replacement, ext, fallback) {
    const prefix = prefixes.find((p) => stem.startsWith(p));
    const name = prefix ? replacement + stem.slice(prefix.length) : `${stem} - ${fallback}`;
    return `${name}.${ext}`;
  }

  function fileNameFor(kind, stem) {
    switch (kind) {
      case 'mergedVideo': return `${stem}.mp4`;
      case 'video': return sibling(stem, ['Snap 录屏 '], 'Snap 视频 ', 'mp4', '视频');
      case 'voice': return sibling(stem, ['Snap 视频 ', 'Snap 录屏 '], 'Snap 人声 ', 'm4a', '人声');
      case 'systemAudio': return sibling(stem, ['Snap 录屏 ', 'Snap 视频 '], 'Snap 电脑声音 ', 'm4a', '电脑声音');
      case 'mixedAudio': return sibling(stem, ['Snap 录屏 ', 'Snap 视频 '], 'Snap 声音 ', 'm4a', '声音');
      default: throw fail('未知的导出文件类型。');
    }
  }

  // 与软件一致：任一目标文件已存在，就整组改用“名称 (2)”“名称 (3)”……不覆盖已有文件
  function fileNamesFor(stem, kinds, existing) {
    let candidate = stem;
    let index = 2;
    for (;;) {
      const names = kinds.map((k) => fileNameFor(k, candidate));
      if (!names.some((n) => existing.has(n))) return names;
      candidate = `${stem} (${index})`;
      index += 1;
    }
  }

  // 样片用的体积推算：视频按导出计划估算（自定义不超过上限），音频按档位码率估算
  function fileBytesFor(kind, info, sel, preset, customMB) {
    const audioRate = PRESETS[preset].audio;
    if (kind === 'systemAudio' || kind === 'voice' || kind === 'mixedAudio') {
      return Math.round(audioRate / 8 * info.duration + 16384);
    }
    const f = selectionFlags(sel);
    const p = planFor(info, sel, preset, customMB);
    if (p.preservesSource) {
      const reserve = f.includesVoiceInVideo ? (f.includesSystemInVideo ? 16384 : audioRate / 8 * info.duration + 16384) : 0;
      return Math.round(info.sourceBytes + reserve);
    }
    let bytes = bytesPerSecond(p) * info.duration + 16384;
    if (preset === 'maximum') {
      const voiceBytes = !f.includesSystemInVideo && f.includesVoiceInVideo ? p.audioBitrate / 8 * info.duration : 0;
      bytes = Math.min(bytes, info.sourceBytes + voiceBytes);
    }
    if (p.byteLimit != null) bytes = Math.min(bytes, p.byteLimit * 0.97);
    return Math.round(bytes);
  }

  const WINDOWS = {
    safari: { app: 'Safari', title: '产品发布会草案', w: 2560, h: 1600 },
    chrome: { app: 'Google Chrome', title: '设计规范 v2', w: 2880, h: 1620 },
    arc: { app: 'Arc', title: '灵感收集', w: 2400, h: 1560 }
  };
  const DISPLAY_SIZE = { w: 3024, h: 1964 };
  const REGION_SIZES = {
    '16:9': { w: 2560, h: 1440 }, '9:16': { w: 1080, h: 1920 }, '4:3': { w: 1920, h: 1440 },
    '3:4': { w: 1440, h: 1920 }, '21:9': { w: 2520, h: 1080 }, '1:1': { w: 1440, h: 1440 },
    custom: { w: 1800, h: 1240 }
  };

  function sourceSize(mode, windowKey, ratio) {
    if (mode === 'display') return { w: DISPLAY_SIZE.w, h: DISPLAY_SIZE.h };
    if (mode === 'region') { const r = REGION_SIZES[ratio] || REGION_SIZES['16:9']; return { w: r.w, h: r.h }; }
    const win = WINDOWS[windowKey] || WINDOWS.safari;
    return { w: win.w, h: win.h };
  }

  // 模拟一段录制原片：码率按屏幕内容的常见压缩率取采集上限的 35%
  function makeInfo(o) {
    const size = sourceSize(o.mode, o.windowKey, o.ratio);
    const duration = Math.max(0.5, o.duration);
    const target = Math.max(24e6, Math.min(68e6, size.w * size.h * 8));
    const sourceVideoBitrate = Math.round(target * 0.35);
    const sourceBytes = Math.round((sourceVideoBitrate + (o.hasSystemAudio ? 128000 : 0)) / 8 * duration + 32768);
    const available = new Set(['video']);
    if (o.hasSystemAudio) available.add('systemAudio');
    if (o.hasMicrophone) available.add('voice');
    return { duration, size, sourceVideoBitrate, sourceFrameRate: FRAME_RATE, sourceBytes, available };
  }

  const Planning = {
    PRESETS, TRACK_TITLES, WINDOWS, formatDuration, outputStem, sizeText, fit, plan, customRecommendation,
    selectionFlags, planFor, recommendationFor, estimateText, customGuidance, parseMegabytes, validateName,
    validationMessage, exportKinds, fileNameFor, fileNamesFor, fileBytesFor, sourceSize, makeInfo
  };
  root.InstrumentPlanning = Planning;
  if (typeof document === 'undefined') return;

  /* ================= 页面交互 ================= */
  const $ = (sel, scope) => (scope || document).querySelector(sel);
  const $$ = (sel, scope) => Array.from((scope || document).querySelectorAll(sel));
  const reduceMotion = !!(root.matchMedia && root.matchMedia('(prefers-reduced-motion: reduce)').matches);

  const MODE_TITLES = { browser: '任意窗口', display: '整个屏幕', region: '局部录像' };
  const POS_TITLES = { topLeft: '左上角', topRight: '右上角', bottomLeft: '左下角', bottomRight: '右下角' };
  const SIZE_FRACTION = { small: 0.18, medium: 0.24, large: 0.32 };
  const PORTRAIT_SUB = {
    original: '保留原始画面，不做修饰',
    natural: '轻柔肤质，保留皮肤纹理',
    soft: '加强柔肤，五官与脸型保持不变'
  };
  const RATIOS = { '16:9': 16 / 9, '9:16': 9 / 16, '4:3': 4 / 3, '3:4': 3 / 4, '21:9': 21 / 9, '1:1': 1 };
  const SCREEN_POINTS = 1512; // 示意屏幕代表的宽度（pt），用于缩放选区圆角

  // 录前设置与录制状态（默认值与软件一致）
  const S = {
    mode: 'browser',
    windowKey: 'safari',
    browserState: 'ok', // ok | loading | empty | error | closed
    permMic: true,
    permCamera: true,
    systemAudio: true,
    mic: false,
    micMessage: null,
    camera: false,
    cameraPreparing: false,
    cameraReady: false,
    cameraMessage: null,
    mouse: true,
    cam: { position: 'bottomRight', shape: 'rounded', size: 'medium', mirrored: true, portrait: 'original' },
    region: { ratio: '16:9', corner: 'rounded', vignette: false, focus: false, focusCorner: 'rounded', locked: false },
    phase: 'idle', // idle | countdown | recording | paused
    countdown: 3,
    elapsedBefore: 0,
    segmentStart: null,
    recDate: null,
    active: null,
    lastActive: null,
    releasedCamera: false,
    annotate: true
  };

  // 导出会话
  const X = {
    info: null,
    origin: null, // demo | recording
    demoKind: 'va',
    tracks: new Set(),
    arrangement: 'merged',
    preset: 'maximum',
    customMB: '20',
    name: '',
    view: 'choose', // choose | progress
    progress: null, // preparing | exporting | cancelling
    outputs: [],
    error: null
  };
  const downloads = new Set(); // 模拟“下载”里已有的文件名，用来演示不覆盖
  const timers = {};
  let sheetOpen = false;
  let alertOpen = false;

  function clearTimer(key) {
    if (timers[key]) { clearTimeout(timers[key]); clearInterval(timers[key]); timers[key] = null; }
  }

  const el = {
    setupWindow: $('#setup-window'),
    setupBody: $('#setup-window .setup-body'),
    sourceTabs: $('#setup-window .source-tabs'),
    ratioGrid: $('#setup-window .ratio-grid'),
    veil: $('#setup-veil'),
    veilTitle: $('#setup-veil-title'),
    veilText: $('#setup-veil-text'),
    windowSelect: $('#window-select'),
    refresh: $('#refresh-windows'),
    browserHint: $('#browser-hint'),
    browserNote: $('#browser-note'),
    lockHint: $('#region-lock-hint'),
    focusSub: $('#focus-sub'),
    vignetteRow: $('[data-row="vignette"]'),
    focusRow: $('[data-row="focus"]'),
    regionCornerSeg: $('[data-seg="regionCorner"]'),
    focusCornerSeg: $('[data-seg="focusCorner"]'),
    micSub: $('#mic-sub'),
    micSettings: $('#mic-settings'),
    cameraSub: $('#camera-sub'),
    cameraSettings: $('#camera-settings'),
    cameraStyle: $('#camera-style'),
    cameraSpinner: $('#camera-spinner'),
    mouseSub: $('#mouse-sub'),
    start: $('#start-recording'),
    sheet: $('#camera-sheet'),
    scrim: $('#camera-scrim'),
    posGrid: $('#camera-sheet .pos-grid'),
    shapeSeg: $('[data-seg="shape"]'),
    sizeSeg: $('[data-seg="size"]'),
    portraitSeg: $('[data-seg="portrait"]'),
    portraitSub: $('#portrait-sub'),
    setupStatus: $('#setup-status'),

    stage: $('#stage'),
    stageWindow: $('#stage-window'),
    stageWindowTitle: $('#stage-window-title'),
    anno: $('#anno-capture'),
    annoText: $('#anno-capture-text'),
    region: $('#stage-region'),
    hole: $('#region-hole'),
    focus: $('#region-focus'),
    badge: $('#region-badge'),
    cam: $('#stage-cam'),
    cursor: $('#stage-cursor'),
    countNum: $('#countdown-num'),
    countRing: $('#countdown-ring'),
    hud: $('#stage-hud'),
    hudTime: $('#hud-time'),
    hudPause: $('#hud-pause'),
    hudPauseIcon: $('#hud-pause-icon'),
    hudStop: $('#hud-stop'),
    stageTip: $('#stage-tip'),
    simStart: $('#sim-start'),
    simPause: $('#sim-pause'),
    simStop: $('#sim-stop'),
    simStatus: $('#sim-status'),
    pinCam: $('.pin[data-pin="cam"]'),
    pinRegion: $('.pin[data-pin="region"]'),
    pinFocus: $('.pin[data-pin="focus"]'),
    pinVignette: $('.pin[data-pin="vignette"]'),

    exportWindow: $('#export-window'),
    exportChoose: $('#export-window [data-pane-view="choose"]'),
    exportProgress: $('#export-window [data-pane-view="progress"]'),
    exportVeil: $('#export-veil'),
    exportDemo: $('#export-demo'),
    duration: $('#exp-duration'),
    arrangementSeg: $('[data-seg="arrangement"]'),
    qualitySeg: $('[data-seg="quality"]'),
    sizeRow: $('#exp-size-row'),
    custom: $('#exp-custom'),
    customMB: $('#exp-custom-mb'),
    guidance: $('#exp-custom-guidance'),
    estimate: $('#exp-estimate'),
    name: $('#exp-name'),
    error: $('#exp-error'),
    saved: $('#exp-saved'),
    savedCount: $('#exp-saved-count'),
    savedList: $('#exp-saved-list'),
    reveal: $('#exp-reveal'),
    save: $('#exp-save'),
    saveLabel: $('#exp-save-label'),
    discard: $('#exp-discard'),
    restart: $('#exp-restart'),
    progressText: $('#exp-progress-text'),
    cancel: $('#exp-cancel'),
    alert: $('#exp-alert'),
    alertScrim: $('#alert-scrim'),
    alertContinue: $('#alert-continue'),
    alertDiscard: $('#alert-discard'),
    exportStatus: $('#export-status')
  };
  const sw = {};
  ['vignette', 'focusMask', 'systemAudio', 'mic', 'camera', 'mouse', 'mirrored', 'annotate'].forEach((key) => {
    sw[key] = $(`[data-toggle="${key}"]`);
  });

  /* ---------- 通用控件行为 ---------- */
  function markRadio(group, value, key) {
    const attr = key || 'value';
    $$('[role="radio"]', group).forEach((item) => {
      const on = item.dataset[attr] === value;
      item.setAttribute('aria-checked', on ? 'true' : 'false');
      item.tabIndex = on ? 0 : -1;
    });
  }

  // 单选组：点击选择；方向键、Home、End 在可用项之间移动并选择
  function bindRadioGroup(group, key, onPick) {
    group.addEventListener('click', (e) => {
      const item = e.target.closest('[role="radio"]');
      if (!item || !group.contains(item) || item.disabled) return;
      onPick(item.dataset[key]);
    });
    group.addEventListener('keydown', (e) => {
      const item = e.target.closest('[role="radio"]');
      if (!item) return;
      const list = $$('[role="radio"]', group).filter((n) => !n.disabled);
      let i = list.indexOf(item);
      if (i < 0) return;
      if (e.key === 'ArrowRight' || e.key === 'ArrowDown') i = (i + 1) % list.length;
      else if (e.key === 'ArrowLeft' || e.key === 'ArrowUp') i = (i - 1 + list.length) % list.length;
      else if (e.key === 'Home') i = 0;
      else if (e.key === 'End') i = list.length - 1;
      else return;
      e.preventDefault();
      onPick(list[i].dataset[key]);
      list[i].focus();
    });
  }

  function bindSwitch(node, handler) {
    node.addEventListener('click', () => {
      if (node.disabled) return;
      handler(node.getAttribute('aria-checked') !== 'true');
    });
  }

  function setSwitch(node, on, disabled) {
    node.setAttribute('aria-checked', on ? 'true' : 'false');
    if (disabled !== undefined) node.disabled = !!disabled;
  }

  function setText(node, text) {
    if (node.textContent !== text) node.textContent = text;
  }

  function restartAnimation(node, cls) {
    node.classList.remove(cls);
    if (reduceMotion) return;
    void node.getBoundingClientRect();
    node.classList.add(cls);
  }

  function scrollToSample(id) {
    const target = document.getElementById(id);
    if (target) target.scrollIntoView({ behavior: reduceMotion ? 'auto' : 'smooth', block: 'start' });
  }

  function isCapturing() { return S.phase === 'recording' || S.phase === 'paused'; }
  function sessionBlocking() { return !!X.info && X.origin === 'recording'; }
  function canStart() {
    if (S.mode !== 'browser') return true;
    return S.browserState === 'ok' && !!S.windowKey;
  }

  /* ---------- 样片 01：录前设置 ---------- */
  function setLockHint(locked) {
    const kbd = document.createElement('kbd');
    kbd.textContent = '⌘E';
    el.lockHint.replaceChildren(
      document.createTextNode(locked ? '浮层已锁定 · ' : '拖动虚线框 · '),
      kbd,
      document.createTextNode(locked ? ' 调整' : ' 锁定')
    );
    el.lockHint.classList.toggle('is-locked', locked);
  }

  function syncReviewChips() {
    $$('[data-review]').forEach((chip) => {
      const parts = chip.dataset.review.split(':');
      let pressed = false;
      if (parts[0] === 'browser') pressed = parts[1] === S.browserState;
      if (parts[0] === 'perm') {
        pressed = parts[1] === 'ok' ? (S.permMic && S.permCamera)
          : parts[1] === 'mic' ? !S.permMic : !S.permCamera;
      }
      if (parts[0] === 'region') pressed = S.region.locked;
      chip.setAttribute('aria-pressed', pressed ? 'true' : 'false');
    });
  }

  function renderSetup() {
    const busy = S.phase !== 'idle';
    const blocking = busy || sessionBlocking();

    markRadio(el.sourceTabs, S.mode, 'mode');
    $$('#setup-window .source-pane').forEach((pane) => { pane.hidden = pane.dataset.pane !== S.mode; });
    el.setupWindow.dataset.mode = S.mode;

    const shownState = S.browserState === 'closed' ? 'ok' : S.browserState;
    $$('#setup-window .browser-state').forEach((node) => { node.hidden = node.dataset.state !== shownState; });
    if (S.browserState === 'closed' || !S.windowKey) el.windowSelect.selectedIndex = -1;
    else el.windowSelect.value = S.windowKey;
    el.browserNote.hidden = S.browserState !== 'closed';
    el.browserHint.hidden = S.browserState === 'closed';

    markRadio(el.ratioGrid, S.region.ratio, 'ratio');
    setLockHint(S.region.locked);
    markRadio(el.regionCornerSeg, S.region.corner);
    const vignetteEnabled = S.region.corner === 'rounded';
    setSwitch(sw.vignette, S.region.vignette, !vignetteEnabled);
    el.vignetteRow.classList.toggle('is-disabled', !vignetteEnabled);
    const focusAvailable = S.region.ratio !== 'custom';
    setSwitch(sw.focusMask, S.region.focus, !focusAvailable);
    el.focusRow.classList.toggle('is-disabled', !focusAvailable);
    setText(el.focusSub, focusAvailable ? '框内原色，框外单色并压暗 50%' : '选择固定比例后可用');
    el.focusCornerSeg.hidden = !S.region.focus;
    markRadio(el.focusCornerSeg, S.region.focusCorner);

    setSwitch(sw.systemAudio, S.systemAudio);
    setSwitch(sw.mic, S.mic);
    setText(el.micSub, S.micMessage || (S.mic ? '结束后可合并或分开导出' : '使用系统默认麦克风'));
    el.micSub.classList.toggle('is-warn', !!S.micMessage);
    el.micSettings.hidden = !S.micMessage;

    setSwitch(sw.camera, S.camera);
    sw.camera.classList.toggle('is-busy', S.cameraPreparing);
    setText(el.cameraSub, S.cameraMessage ||
      (S.cameraPreparing ? '正在准备摄像头…' : (S.camera ? `人像叠入成片 · ${POS_TITLES[S.cam.position]}` : '把你和屏幕一起录下来')));
    el.cameraSub.classList.toggle('is-warn', !!S.cameraMessage);
    el.cameraSettings.hidden = !S.cameraMessage;
    el.cameraStyle.hidden = !S.cameraReady;
    el.cameraSpinner.hidden = !S.cameraPreparing;

    setSwitch(sw.mouse, S.mouse);
    setText(el.mouseSub, S.mouse ? '准星跟随，点击时扩散' : '成片不显示鼠标');
    el.start.disabled = !canStart();

    markRadio(el.posGrid, S.cam.position, 'pos');
    markRadio(el.shapeSeg, S.cam.shape);
    markRadio(el.sizeSeg, S.cam.size);
    markRadio(el.portraitSeg, S.cam.portrait);
    setSwitch(sw.mirrored, S.cam.mirrored);
    setText(el.portraitSub, PORTRAIT_SUB[S.cam.portrait]);

    el.veil.hidden = !blocking;
    if (busy) {
      setText(el.veilTitle, '主面板已自动收起');
      setText(el.veilText, '录制中再次打开 Snap Recorder 可调出主面板；主动拖入画面时会被录入。');
    } else if (blocking) {
      setText(el.veilTitle, '主面板正在显示导出页');
      setText(el.veilText, '命名与导出见下方样片 03；完成、放弃或重新录制后回到这里。');
    }
    el.setupBody.inert = blocking || sheetOpen;
    el.sheet.inert = blocking;
    syncReviewChips();
  }

  function setSetupStatus(text) { setText(el.setupStatus, text); }

  function setMic(on) {
    if (S.phase !== 'idle') return;
    if (!on) { S.mic = false; S.micMessage = null; }
    else if (!S.permMic) { S.mic = false; S.micMessage = '麦克风权限未开启'; }
    else { S.mic = true; S.micMessage = null; }
    renderAll();
  }

  function setCamera(on) {
    if (S.phase !== 'idle') return;
    clearTimer('camera');
    if (!on) {
      S.camera = false; S.cameraPreparing = false; S.cameraReady = false; S.cameraMessage = null;
      closeSheet(false);
      setSetupStatus('（模拟）摄像头已关闭并释放。');
      renderAll();
      return;
    }
    S.camera = true; S.cameraPreparing = true; S.cameraReady = false; S.cameraMessage = null;
    renderAll();
    timers.camera = setTimeout(() => {
      S.cameraPreparing = false;
      if (!S.permCamera) {
        S.camera = false; S.cameraMessage = '摄像头权限未开启';
      } else {
        S.cameraReady = true;
        setSetupStatus('（模拟）摄像头已就绪：预览出现在样片 02 的示意屏幕上，未调用真实摄像头。');
      }
      renderAll();
    }, reduceMotion ? 0 : 700);
  }

  function openSheet() {
    if (!S.cameraReady || S.phase !== 'idle' || sessionBlocking()) return;
    sheetOpen = true;
    el.sheet.hidden = false;
    el.scrim.hidden = false;
    renderSetup();
    const first = $('.pos[aria-checked="true"]', el.sheet) || $('button', el.sheet);
    if (first) first.focus();
  }

  function closeSheet(focusBack) {
    if (!sheetOpen) return;
    sheetOpen = false;
    el.sheet.hidden = true;
    el.scrim.hidden = true;
    renderSetup();
    if (focusBack && !el.cameraStyle.hidden) el.cameraStyle.focus();
  }

  function bindSetup() {
    bindRadioGroup(el.sourceTabs, 'mode', (mode) => {
      if (S.phase !== 'idle' || sessionBlocking()) return;
      S.mode = mode;
      if (mode !== 'region') S.region.locked = false;
      renderAll();
    });
    el.windowSelect.addEventListener('change', () => {
      S.windowKey = el.windowSelect.value || null;
      if (S.windowKey) S.browserState = 'ok';
      renderAll();
    });
    el.refresh.addEventListener('click', () => {
      clearTimer('refresh');
      S.browserState = 'loading';
      renderAll();
      timers.refresh = setTimeout(() => {
        S.browserState = 'ok';
        if (!S.windowKey) S.windowKey = 'safari';
        renderAll();
      }, reduceMotion ? 0 : 700);
    });
    bindRadioGroup(el.ratioGrid, 'ratio', (ratio) => {
      S.region.ratio = ratio;
      if (ratio === 'custom') S.region.focus = false;
      renderAll();
    });
    bindRadioGroup(el.regionCornerSeg, 'value', (v) => { S.region.corner = v; renderAll(); });
    bindRadioGroup(el.focusCornerSeg, 'value', (v) => { S.region.focusCorner = v; renderAll(); });
    bindSwitch(sw.vignette, (on) => { S.region.vignette = on; renderAll(); });
    bindSwitch(sw.focusMask, (on) => { if (S.region.ratio !== 'custom') { S.region.focus = on; renderAll(); } });
    bindSwitch(sw.systemAudio, (on) => { S.systemAudio = on; renderAll(); });
    bindSwitch(sw.mic, setMic);
    bindSwitch(sw.camera, setCamera);
    bindSwitch(sw.mouse, (on) => { S.mouse = on; renderAll(); });
    el.micSettings.addEventListener('click', () => setSetupStatus('（模拟）会打开“系统设置 › 隐私与安全性 › 麦克风”。'));
    el.cameraSettings.addEventListener('click', () => setSetupStatus('（模拟）会打开“系统设置 › 隐私与安全性 › 摄像头”。'));
    el.cameraStyle.addEventListener('click', openSheet);
    el.scrim.addEventListener('click', () => closeSheet(true));
    $$('[data-close-sheet]', el.sheet).forEach((b) => b.addEventListener('click', () => closeSheet(true)));
    el.sheet.addEventListener('keydown', (e) => {
      if (e.key !== 'Tab') return;
      const focusable = $$('button:not([disabled])', el.sheet).filter((n) => n.tabIndex >= 0 && n.offsetParent !== null);
      if (!focusable.length) return;
      const first = focusable[0];
      const last = focusable[focusable.length - 1];
      if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
      else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
    });
    bindRadioGroup(el.posGrid, 'pos', (v) => { S.cam.position = v; renderAll(); });
    bindRadioGroup(el.shapeSeg, 'value', (v) => { S.cam.shape = v; renderAll(); });
    bindRadioGroup(el.sizeSeg, 'value', (v) => { S.cam.size = v; renderAll(); });
    bindRadioGroup(el.portraitSeg, 'value', (v) => { S.cam.portrait = v; renderAll(); });
    bindSwitch(sw.mirrored, (on) => { S.cam.mirrored = on; renderAll(); });
    el.start.addEventListener('click', () => startRecording(true));

    $$('[data-review]').forEach((chip) => chip.addEventListener('click', () => {
      if (S.phase !== 'idle') { setSetupStatus('录制模拟进行中，结束后再切换状态。'); return; }
      const parts = chip.dataset.review.split(':');
      const group = parts[0];
      const value = parts[1];
      if (group === 'browser') {
        clearTimer('refresh');
        if (sessionBlocking()) { setSetupStatus('导出页打开时主面板不可操作，请先在样片 03 完成或放弃。'); return; }
        S.mode = 'browser';
        S.region.locked = false;
        S.browserState = value;
        if (value === 'closed') S.windowKey = null;
        else if (!S.windowKey) S.windowKey = 'safari';
      } else if (group === 'perm') {
        S.permMic = value !== 'mic';
        S.permCamera = value !== 'camera';
        if (value === 'ok') { S.micMessage = null; S.cameraMessage = null; }
        if (!S.permMic && S.mic) { S.mic = false; S.micMessage = '麦克风权限未开启'; }
        if (!S.permCamera && (S.camera || S.cameraPreparing)) {
          clearTimer('camera');
          S.camera = false; S.cameraReady = false; S.cameraPreparing = false; S.cameraMessage = '摄像头权限未开启';
          closeSheet(false);
        }
        setSetupStatus(value === 'ok' ? '（模拟）权限都已允许。' : '（模拟）权限未开启：打开对应开关即可看到提示。');
      } else if (group === 'region') {
        if (sessionBlocking()) { setSetupStatus('导出页打开时主面板不可操作，请先在样片 03 完成或放弃。'); return; }
        S.mode = 'region';
        S.region.locked = !S.region.locked;
        setSetupStatus(S.region.locked ? '（模拟 ⌘E）选区浮层已锁定，指针可穿过浮层操作下面的窗口。' : '（模拟 ⌘E）选区浮层可再次拖动调整。');
      }
      renderAll();
    }));
  }

  /* ---------- 样片 02：示意屏幕与录制流程 ---------- */
  function elapsed() {
    return S.elapsedBefore + (S.segmentStart != null ? (performance.now() - S.segmentStart) / 1000 : 0);
  }

  function layoutStageWindow(W, H) {
    const win = WINDOWS[S.windowKey || 'safari'] || WINDOWS.safari;
    const ratio = win.w / win.h;
    let w = W * 0.66;
    let h = w / ratio;
    if (h > H * 0.78) { h = H * 0.78; w = h * ratio; }
    Object.assign(el.stageWindow.style, { left: `${W * 0.09}px`, top: `${H * 0.12}px`, width: `${w}px`, height: `${h}px` });
    setText(el.stageWindowTitle, win.title);
    return { x: W * 0.09, y: H * 0.12, w, h };
  }

  function regionRect(W, H) {
    let w;
    let h;
    if (S.region.ratio === 'custom') { w = W * 0.5; h = H * 0.56; }
    else {
      const r = RATIOS[S.region.ratio];
      w = Math.min(W * 0.62, H * 0.66 * r);
      h = w / r;
    }
    return { x: (W - w) / 2, y: H * 0.54 - h / 2, w, h };
  }

  function placePin(pin, x, y, alignRight, W) {
    pin.style.transform = alignRight ? 'translateX(-100%)' : 'none';
    pin.style.left = `${x}px`;
    pin.style.top = `${y}px`;
    if (pin.offsetWidth) {
      const left = alignRight ? x - pin.offsetWidth : x;
      if (left < 8) { pin.style.transform = 'none'; pin.style.left = '8px'; }
      else if (left + pin.offsetWidth > W - 8) { pin.style.transform = 'none'; pin.style.left = `${W - 8 - pin.offsetWidth}px`; }
    }
  }

  function stageStatus() {
    if (S.phase === 'countdown') return `倒计时 ${S.countdown}：主面板已自动收起${S.mode === 'region' ? '，选区浮层已锁定' : ''}。`;
    if (S.phase === 'recording') return '录制中（模拟，不采集任何画面与声音）。按 Esc 或点结束按钮结束。';
    if (S.phase === 'paused') return '已暂停（模拟）。点“继续”恢复计时。';
    if (sessionBlocking()) {
      return S.releasedCamera ? '录制已结束：摄像头已释放，主面板回到导出页（见样片 03）。' : '录制已结束：主面板回到导出页（见样片 03）。';
    }
    return canStart() ? `待命：来源为${MODE_TITLES[S.mode]}。` : '待命：请先在样片 01 选择一个窗口。';
  }

  function renderStage() {
    const d = el.stage.dataset;
    const W = el.stage.clientWidth;
    const H = el.stage.clientHeight;
    const scale = W > 0 ? W / SCREEN_POINTS : 0.7;
    const cameraOn = S.camera && S.cameraReady;

    d.mode = S.mode;
    d.phase = S.phase;
    d.annotate = S.annotate ? 'on' : 'off';
    d.camera = cameraOn ? 'on' : 'off';
    d.mouse = S.mouse ? 'on' : 'off';
    d.focus = S.mode === 'region' && S.region.focus ? 'on' : 'off';
    d.vignette = S.mode === 'region' && S.region.vignette && S.region.corner === 'rounded' ? 'on' : 'off';
    d.session = sessionBlocking() ? 'export' : 'none';

    const win = layoutStageWindow(W, H);
    let rect;
    if (S.mode === 'display') {
      rect = { x: 0, y: 0, w: W, h: H };
      Object.assign(el.anno.style, { left: '6px', top: '6px', width: `${W - 12}px`, height: `${H - 12}px` });
      setText(el.annoText, '注 · 成片范围：当前主屏幕，本应用的浮窗不进成片');
    } else if (S.mode === 'region') {
      rect = regionRect(W, H);
    } else {
      rect = win;
      Object.assign(el.anno.style, { left: `${win.x - 5}px`, top: `${win.y - 5}px`, width: `${win.w + 10}px`, height: `${win.h + 10}px` });
      setText(el.annoText, '注 · 成片范围：只含这个窗口，按窗口原始比例');
    }

    // 选区浮层
    const regionRadius = Math.max(4, 12 * scale);
    Object.assign(el.region.style, { left: `${rect.x}px`, top: `${rect.y}px`, width: `${rect.w}px`, height: `${rect.h}px` });
    el.region.style.setProperty('--region-r', `${regionRadius}px`);
    el.region.style.setProperty('--vf-r', `${regionRadius + 5}px`);
    el.region.dataset.corner = S.region.corner;
    el.region.dataset.locked = S.region.locked || S.phase !== 'idle' ? 'true' : 'false';
    el.region.dataset.live = isCapturing() ? 'true' : 'false';
    el.region.dataset.focus = d.focus;
    const focusRect = { x: rect.w * 0.2, y: rect.h * 0.2, w: rect.w * 0.6, h: rect.h * 0.6 };
    const focusRadius = S.region.focusCorner === 'rounded' ? `${regionRadius}px` : '0px';
    [el.hole, el.focus].forEach((node) => {
      Object.assign(node.style, { left: `${focusRect.x}px`, top: `${focusRect.y}px`, width: `${focusRect.w}px`, height: `${focusRect.h}px` });
      node.style.setProperty('--focus-r', focusRadius);
    });
    const ratioTitle = S.region.ratio === 'custom' ? '自定义' : S.region.ratio;
    const locked = el.region.dataset.locked === 'true';
    const instruction = locked ? '浮层已锁定 · ⌘E 调整' : (S.region.focus ? '拖动内框聚焦 · ⌘E 锁定' : '拖动框内移动 · ⌘E 锁定');
    setText(el.badge, `${ratioTitle}  ·  ${instruction}`);

    // 人像预览：按成片短边比例放在所选角落
    const short = Math.min(rect.w, rect.h);
    const side = short * SIZE_FRACTION[S.cam.size];
    const margin = short * 0.035;
    const right = S.cam.position === 'topRight' || S.cam.position === 'bottomRight';
    const bottom = S.cam.position === 'bottomLeft' || S.cam.position === 'bottomRight';
    const camX = right ? rect.x + rect.w - margin - side : rect.x + margin;
    const camY = bottom ? rect.y + rect.h - margin - side : rect.y + margin;
    Object.assign(el.cam.style, { left: `${camX}px`, top: `${camY}px`, width: `${side}px`, height: `${side}px` });
    el.cam.dataset.shape = S.cam.shape;
    el.cam.dataset.mirrored = S.cam.mirrored ? 'true' : 'false';

    // 标注位置
    if (cameraOn) {
      if (camY > 40) placePin(el.pinCam, right ? camX + side : camX, camY - 30, right, W);
      else placePin(el.pinCam, right ? camX + side : camX, camY + side + 8, right, W);
    }
    if (S.mode === 'region') {
      placePin(el.pinRegion, rect.x + rect.w + 12, rect.y + rect.h - 22, false, W);
      placePin(el.pinVignette, rect.x + rect.w + 12, rect.y + rect.h - 52, false, W);
      placePin(el.pinFocus, rect.x + focusRect.x + 8, rect.y + focusRect.y + 8, false, W);
    }

    // 倒计时与控制条
    setText(el.countNum, String(S.countdown));
    const paused = S.phase === 'paused';
    el.hud.dataset.paused = paused ? 'true' : 'false';
    setText(el.hudTime, paused ? '已暂停' : formatDuration(elapsed()));
    el.hudPauseIcon.setAttribute('href', paused ? '#i-play' : '#i-pause');
    const pauseLabel = paused ? '继续' : '暂停';
    el.hudPause.title = pauseLabel;
    el.hudPause.setAttribute('aria-label', pauseLabel);
    setText(el.simPause, pauseLabel);

    el.simStart.disabled = S.phase !== 'idle' || !canStart() || sessionBlocking();
    el.simPause.disabled = !isCapturing();
    el.simStop.disabled = !isCapturing();
    setText(el.stageTip, sessionBlocking()
      ? '录制已结束，请在样片 03 命名与导出。'
      : '点“开始模拟”或上方的“开始录制”。录制鼠标开启时，指针处会示意成片里的准星（屏幕上仍是普通指针），点击会扩散。');
    setText(el.simStatus, stageStatus());
    setSwitch(sw.annotate, S.annotate);
  }

  function startRecording(scroll) {
    if (S.phase !== 'idle' || !canStart() || sessionBlocking()) return;
    if (X.origin === 'demo') { X.info = null; X.origin = null; }
    closeSheet(false);
    clearTimer('refresh');
    S.phase = 'countdown';
    S.countdown = 3;
    S.recDate = new Date();
    S.releasedCamera = false;
    S.active = {
      mode: S.mode, windowKey: S.windowKey, ratio: S.region.ratio,
      systemAudio: S.systemAudio, mic: S.mic, camera: S.camera && S.cameraReady
    };
    if (S.mode === 'region') S.region.locked = true;
    renderAll();
    if (scroll) scrollToSample('sample-recording');
    runCountdown();
  }

  function runCountdown() {
    renderStage();
    // 数字直接切换，只让指针每秒扫一圈
    restartAnimation(el.countRing, 'is-run');
    clearTimer('countdown');
    timers.countdown = setTimeout(() => {
      if (S.phase !== 'countdown') return;
      if (S.countdown > 1) { S.countdown -= 1; runCountdown(); }
      else beginRecording();
    }, 1000);
  }

  function beginRecording() {
    S.phase = 'recording';
    S.elapsedBefore = 0;
    S.segmentStart = performance.now();
    clearTimer('tick');
    timers.tick = setInterval(() => {
      if (S.phase === 'recording') setText(el.hudTime, formatDuration(elapsed()));
    }, 250);
    renderAll();
    el.hudPause.focus({ preventScroll: true });
  }

  function togglePause() {
    if (S.phase === 'recording') { S.elapsedBefore = elapsed(); S.segmentStart = null; S.phase = 'paused'; }
    else if (S.phase === 'paused') { S.segmentStart = performance.now(); S.phase = 'recording'; }
    else return;
    renderAll();
  }

  function stopRecording() {
    if (!isCapturing()) return;
    const duration = elapsed();
    clearTimer('tick');
    S.phase = 'idle';
    S.segmentStart = null;
    S.elapsedBefore = 0;
    S.lastActive = S.active;
    // 录制结束即释放摄像头
    S.releasedCamera = S.camera;
    S.camera = false; S.cameraReady = false; S.cameraPreparing = false;
    closeSheet(false);
    const a = S.active;
    const info = makeInfo({
      mode: a.mode, windowKey: a.windowKey, ratio: a.ratio, duration,
      hasSystemAudio: a.systemAudio, hasMicrophone: a.mic
    });
    openSession(info, S.recDate, 'recording', false);
    scrollToSample('sample-export');
  }

  function bindStage() {
    el.simStart.addEventListener('click', () => startRecording(false));
    el.simPause.addEventListener('click', togglePause);
    el.simStop.addEventListener('click', stopRecording);
    el.hudPause.addEventListener('click', togglePause);
    el.hudStop.addEventListener('click', stopRecording);
    bindSwitch(sw.annotate, (on) => { S.annotate = on; renderStage(); });

    // 成片鼠标准星示意：只跟随指针，不读取系统鼠标
    el.stage.addEventListener('pointermove', (e) => {
      const r = el.stage.getBoundingClientRect();
      el.cursor.style.transform = `translate(${e.clientX - r.left}px, ${e.clientY - r.top}px)`;
      el.stage.classList.add('is-pointer');
    });
    el.stage.addEventListener('pointerleave', () => el.stage.classList.remove('is-pointer'));
    el.stage.addEventListener('pointerdown', (e) => {
      if (!S.mouse || e.target.closest('button')) return;
      const r = el.stage.getBoundingClientRect();
      const ring = document.createElement('span');
      ring.className = 'ripple';
      ring.style.left = `${e.clientX - r.left}px`;
      ring.style.top = `${e.clientY - r.top}px`;
      el.stage.appendChild(ring);
      const remove = () => ring.remove();
      ring.addEventListener('animationend', remove);
      setTimeout(remove, 1000);
    });

    if (typeof ResizeObserver !== 'undefined') new ResizeObserver(() => renderStage()).observe(el.stage);
    else root.addEventListener('resize', renderStage);
  }

  /* ---------- 样片 03：命名与导出 ---------- */
  function currentSelection() { return { tracks: X.tracks, arrangement: X.arrangement }; }
  function setExportStatus(text) { setText(el.exportStatus, text); }

  function openSession(info, date, origin, instant) {
    clearTimer('export');
    clearTimer('exportPrep');
    X.info = info;
    X.origin = origin;
    X.tracks = new Set(info.available);
    X.arrangement = X.tracks.has('voice') ? 'separate' : 'merged';
    X.preset = 'maximum';
    X.error = null;
    X.outputs = [];
    X.name = outputStem(date);
    try { X.customMB = Planning.recommendationFor(info, currentSelection()).suggestedMaximum.toFixed(1); }
    catch (e) { X.customMB = '20'; }
    closeAlert(false);
    if (instant) { X.view = 'choose'; X.progress = null; }
    else {
      X.view = 'progress';
      X.progress = 'preparing';
      timers.exportPrep = setTimeout(() => {
        X.view = 'choose'; X.progress = null;
        renderExport();
        // 焦点丢失或停在已隐藏的控制条上时，交给名称输入框，键盘用户可直接命名
        const active = document.activeElement;
        if (!active || active === document.body || el.stage.contains(active)) el.name.focus({ preventScroll: true });
      }, reduceMotion ? 0 : 700);
    }
    renderAll();
  }

  function loadDemo(kind) {
    X.demoKind = kind;
    const info = makeInfo({
      mode: 'browser', windowKey: 'safari', duration: 134,
      hasSystemAudio: kind !== 'v', hasMicrophone: kind === 'vav'
    });
    openSession(info, new Date(2026, 8, 28, 20, 31, 7), 'demo', true);
  }

  function endSession(reason) {
    if (!X.info || X.view === 'progress') return false;
    const saved = X.outputs.length > 0;
    X.info = null;
    X.origin = null;
    X.outputs = [];
    X.error = null;
    closeAlert(false);
    S.region.locked = false;
    S.releasedCamera = false;
    if (reason === 'restart') setExportStatus('（模拟）已结束这次导出，直接重新录制。');
    else if (saved) setExportStatus('（模拟）已完成：已保存的文件留在“下载”，临时原片已清理。');
    else setExportStatus('（模拟）已放弃：未保存的临时原片移到废纸篓。');
    renderAll();
    return true;
  }

  function restartRecording() {
    const restoreCamera = !!(X.origin === 'recording' && S.lastActive && S.lastActive.camera);
    if (!endSession('restart')) return;
    if (restoreCamera && S.permCamera) { S.camera = true; S.cameraReady = true; S.cameraMessage = null; }
    if (!canStart()) {
      setExportStatus('（模拟）当前来源不可用，请先在样片 01 选择窗口。');
      renderAll();
      return;
    }
    startRecording(true);
  }

  function doExport(instant) {
    if (!X.info || X.view === 'progress') return;
    if (Planning.validationMessage(X.info, currentSelection(), X.preset, X.customMB, X.name)) { renderExport(); return; }
    const job = {
      stem: Planning.validateName(X.name, '录屏'),
      sel: { tracks: new Set(X.tracks), arrangement: X.arrangement },
      preset: X.preset,
      customMB: Planning.parseMegabytes(X.customMB)
    };
    if (instant) { finishExport(job); return; }
    X.view = 'progress';
    X.progress = 'exporting';
    renderExport();
    el.cancel.focus({ preventScroll: true });
    clearTimer('export');
    timers.export = setTimeout(() => finishExport(job), reduceMotion ? 600 : 2200);
  }

  function finishExport(job) {
    clearTimer('export');
    const kinds = Planning.exportKinds(job.sel);
    const names = Planning.fileNamesFor(job.stem, kinds, downloads);
    const files = kinds.map((k, i) => ({ name: names[i], bytes: Planning.fileBytesFor(k, X.info, job.sel, job.preset, job.customMB) }));
    names.forEach((n) => downloads.add(n));
    X.outputs = X.outputs.concat(files);
    X.view = 'choose';
    X.progress = null;
    renderExport();
    setExportStatus(`（模拟）已保存到“下载”：${names.join('、')}`);
    el.save.focus({ preventScroll: true });
  }

  function cancelExport() {
    if (X.progress !== 'exporting') return;
    clearTimer('export');
    X.progress = 'cancelling';
    renderExport();
    timers.export = setTimeout(() => {
      X.view = 'choose';
      X.progress = null;
      renderExport();
      setExportStatus('（模拟）已取消导出，原片仍保留。');
      el.save.focus({ preventScroll: true });
    }, reduceMotion ? 0 : 600);
  }

  function openAlert() {
    alertOpen = true;
    el.alert.hidden = false;
    el.alertScrim.hidden = false;
    renderExport();
    el.alertContinue.focus({ preventScroll: true });
  }

  function closeAlert(focusBack) {
    if (!alertOpen) return;
    alertOpen = false;
    el.alert.hidden = true;
    el.alertScrim.hidden = true;
    renderExport();
    if (focusBack) el.save.focus({ preventScroll: true });
  }

  function renderExport() {
    const has = !!X.info;
    el.exportVeil.hidden = has;
    el.exportChoose.hidden = !has || X.view !== 'choose';
    el.exportProgress.hidden = !has || X.view !== 'progress';
    el.exportWindow.dataset.view = has ? X.view : 'none';
    el.exportChoose.inert = alertOpen;
    $$('[data-xreview]').forEach((chip) => {
      const parts = chip.dataset.xreview.split(':');
      if (parts[0] === 'rec') chip.setAttribute('aria-pressed', X.origin === 'demo' && X.demoKind === parts[1] ? 'true' : 'false');
    });
    if (!has) return;

    const info = X.info;
    const sel = currentSelection();
    setText(el.duration, formatDuration(info.duration));
    $$('#export-window input[data-track]').forEach((input) => {
      const t = input.dataset.track;
      const available = info.available.has(t);
      input.checked = X.tracks.has(t);
      input.disabled = !available;
      const label = input.closest('label');
      label.classList.toggle('is-disabled', !available);
      label.classList.toggle('is-on', input.checked);
      label.title = available ? TRACK_TITLES[t] : `未录制${TRACK_TITLES[t]}`;
    });
    markRadio(el.arrangementSeg, X.arrangement);
    el.sizeRow.hidden = !X.tracks.has('video');
    markRadio(el.qualitySeg, X.preset);
    el.qualitySeg.dataset.value = X.preset;
    el.custom.hidden = X.preset !== 'custom';
    if (document.activeElement !== el.customMB) el.customMB.value = X.customMB;
    setText(el.guidance, Planning.customGuidance(info, sel));
    setText(el.estimate, Planning.estimateText(info, sel, X.preset, Planning.parseMegabytes(X.customMB)));
    if (document.activeElement !== el.name) el.name.value = X.name;

    const validation = Planning.validationMessage(info, sel, X.preset, X.customMB, X.name);
    const message = X.error || validation;
    el.error.hidden = !message;
    setText(el.error, message || '');
    el.name.classList.toggle('is-invalid', !!validation && validation.indexOf('名称') === 0);
    el.customMB.classList.toggle('is-invalid', !!validation && validation.indexOf('视频上限') === 0);
    el.name.setAttribute('aria-invalid', validation && validation.indexOf('名称') === 0 ? 'true' : 'false');

    el.saved.hidden = X.outputs.length === 0;
    setText(el.savedCount, `已保存 ${X.outputs.length} 个文件`);
    el.savedList.replaceChildren(...X.outputs.map((f) => {
      const li = document.createElement('li');
      const file = document.createElement('span');
      file.className = 'file';
      file.textContent = f.name;
      file.title = f.name;
      const leader = document.createElement('span');
      leader.className = 'leader';
      leader.setAttribute('aria-hidden', 'true');
      const size = document.createElement('span');
      size.className = 'size';
      size.textContent = sizeText(f.bytes);
      li.append(file, leader, size);
      return li;
    }));
    setText(el.saveLabel, X.outputs.length ? '再导出一份' : '保存到下载');
    el.save.disabled = !!validation;
    setText(el.discard, X.outputs.length ? '完成' : '放弃此次录制');

    setText(el.progressText, X.progress === 'preparing' ? '正在整理录制…' : '正在导出…');
    el.cancel.hidden = X.progress === 'preparing';
    setText(el.cancel, X.progress === 'cancelling' ? '正在取消…' : '取消导出');
    el.cancel.disabled = X.progress === 'cancelling';
  }

  function bindExport() {
    $$('#export-window input[data-track]').forEach((input) => input.addEventListener('change', () => {
      const t = input.dataset.track;
      if (!X.info || !X.info.available.has(t)) return;
      if (input.checked) X.tracks.add(t); else X.tracks.delete(t);
      X.error = null;
      renderExport();
    }));
    bindRadioGroup(el.arrangementSeg, 'value', (v) => { X.arrangement = v; X.error = null; renderExport(); });
    bindRadioGroup(el.qualitySeg, 'value', (v) => { X.preset = v; renderExport(); });
    el.customMB.addEventListener('input', () => { X.customMB = el.customMB.value; renderExport(); });
    el.name.addEventListener('input', () => { X.name = el.name.value; renderExport(); });
    el.save.addEventListener('click', () => doExport(false));
    el.cancel.addEventListener('click', cancelExport);
    el.reveal.addEventListener('click', () => setExportStatus(`（模拟）会在访达中选中已保存的 ${X.outputs.length} 个文件。`));
    el.discard.addEventListener('click', () => endSession(X.outputs.length ? 'done' : 'discard'));
    el.restart.addEventListener('click', restartRecording);
    el.alertContinue.addEventListener('click', () => closeAlert(true));
    el.alertDiscard.addEventListener('click', () => {
      alertOpen = false;
      el.alert.hidden = true;
      el.alertScrim.hidden = true;
      endSession('discard');
    });
    el.exportDemo.addEventListener('click', () => loadDemo('va'));

    $$('[data-xreview]').forEach((chip) => chip.addEventListener('click', () => {
      if (X.view === 'progress') { setExportStatus('正在导出，请稍候或先取消导出。'); return; }
      if (isCapturing() || S.phase === 'countdown') { setExportStatus('录制模拟进行中，结束后再切换状态。'); return; }
      const parts = chip.dataset.xreview.split(':');
      if (parts[0] === 'rec') { loadDemo(parts[1]); setExportStatus(''); return; }
      if (!X.info) loadDemo('va');
      switch (parts[1]) {
        case 'audio-only':
          loadDemo('vav');
          X.tracks = new Set(['systemAudio', 'voice']);
          X.arrangement = 'merged';
          setExportStatus('（模拟）纯音频合并时导出一个“Snap 声音”文件。');
          break;
        case 'custom':
          X.tracks.add('video');
          X.preset = 'custom';
          setExportStatus('（模拟）自定义大小是每个 MP4 的上限，交付前会检查实际体积。');
          break;
        case 'name-error':
          X.name = '.发布会/草案';
          setExportStatus('');
          break;
        case 'progress':
          renderExport();
          doExport(false);
          return;
        case 'saved':
          doExport(true);
          return;
        case 'close-alert':
          if (X.outputs.length) setExportStatus('（模拟）已经保存过文件，关闭窗口不会弹出提示。');
          else openAlert();
          return;
        default:
          return;
      }
      X.error = null;
      renderExport();
    }));
  }

  /* ---------- 全局 ---------- */
  function renderAll() {
    renderSetup();
    renderStage();
    renderExport();
  }

  document.addEventListener('keydown', (e) => {
    if (e.key !== 'Escape') return;
    if (alertOpen) { e.preventDefault(); closeAlert(true); return; }
    if (sheetOpen) { e.preventDefault(); closeSheet(true); return; }
    if (isCapturing()) { e.preventDefault(); stopRecording(); }
  });

  bindSetup();
  bindStage();
  bindExport();
  loadDemo('va');
  renderAll();
})(typeof window !== 'undefined' ? window : globalThis);
