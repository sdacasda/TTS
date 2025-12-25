function getHeaders() {
  const headers = {};
  const apiKey = document.getElementById('apiKey')?.value;
  if (apiKey) {
    headers['Authorization'] = `Bearer ${apiKey}`;
  }
  return headers;
}

async function fetchJson(url) {
  const r = await fetch(url, { headers: getHeaders() });
  if (!r.ok) {
    let msg = await r.text();
    try {
      const errObj = JSON.parse(msg);
      if (errObj.detail) msg = errObj.detail;
    } catch (_) {
      // If parsing fails, use the status text or a default message if the body is empty
      if (!msg.trim()) msg = `Request failed: ${r.status} ${r.statusText}`;
    }
    throw new Error(msg);
  }
  return await r.json();
}

function fmt(n) {
  return new Intl.NumberFormat().format(n);
}

async function refreshUsage() {
  const u = await fetchJson('/api/usage/overview');
  const bar = document.getElementById('usageBar');
  const limit = Number(u?.limits?.tts_chars);
  if (Number.isFinite(limit) && limit > 0) state.ttsCharsLimit = limit;
  bar.innerHTML = `
    <div class="metric">
      <div class="label">累计</div>
      <div class="value">TTS ${fmt(u.all_time.tts_chars)} 字符</div>
      <div class="meta">STT ${fmt(u.all_time.stt_seconds)} 秒 · 发音 ${fmt(u.all_time.pron_seconds)} 秒</div>
    </div>
    <div class="metric">
      <div class="label">本月（${u.month_key}）</div>
      <div class="value">TTS ${fmt(u.month.tts_chars)} 字符</div>
      <div class="meta">STT ${fmt(u.month.stt_seconds)} 秒 · 发音 ${fmt(u.month.pron_seconds)} 秒</div>
    </div>
    <div class="metric">
      <div class="label">今日</div>
      <div class="value">TTS ${fmt(u.today.tts_chars)} 字符</div>
      <div class="meta">STT ${fmt(u.today.stt_seconds)} 秒 · 发音 ${fmt(u.today.pron_seconds)} 秒</div>
    </div>
  `;
  updateCharCount();
}

document.getElementById('refreshUsage').addEventListener('click', () => {
  refreshUsage().catch(e => alert(`刷新失败：${e.message}`));
});

document.getElementById('updateApp').addEventListener('click', async () => {
  if (!confirm('确定要更新应用吗？更新后服务将自动重启，大约需要10秒。')) return;
  
  const btn = document.getElementById('updateApp');
  const originalText = btn.textContent;
  btn.disabled = true;
  btn.textContent = '⏳ 更新中...';
  
  try {
    const r = await fetch('/api/update', { method: 'POST', headers: getHeaders() });
    if (!r.ok) {
      const err = await r.text();
      throw new Error(err);
    }
    const data = await r.json();
    alert(data.message || '更新成功！页面将在5秒后自动刷新。');
    
    // 等待服务重启后刷新页面
    setTimeout(() => {
      window.location.reload();
    }, 5000);
  } catch (e) {
    alert(`更新失败：${e.message}`);
    btn.disabled = false;
    btn.textContent = originalText;
  }
});

    // Settings: load and save OPENAI_TTS_API_KEY
    async function loadSettings() {
      try {
        const s = await fetchJson('/api/settings');
        const input = document.getElementById('openaiKey');
        if (input && s.openai_tts_api_key) input.value = s.openai_tts_api_key;
      } catch (e) {
        // Non-fatal
        console.debug('Could not load settings:', e.message);
      }
    }

    document.getElementById('saveOpenAIKey')?.addEventListener('click', async () => {
      const val = document.getElementById('openaiKey')?.value || '';
      try {
        const r = await fetch('/api/settings', {
          method: 'POST',
          headers: Object.assign({'Content-Type': 'application/json'}, getHeaders()),
          body: JSON.stringify({ openai_tts_api_key: val || null }),
        });
        if (!r.ok) throw new Error(await r.text());
        alert('保存成功');
      } catch (e) {
        alert(`保存失败：${e.message}`);
      }
    });

    // Load settings on startup
    window.addEventListener('load', () => {
      loadSettings();
      loadApiKeys();
    });

    // --- API Key management for plugin integration ---
    async function loadApiKeys() {
      try {
        const data = await fetchJson('/api/apikeys');
        const list = document.getElementById('apiKeysList');
        list.innerHTML = '';
        (data.keys || []).forEach(k => {
          const row = document.createElement('div');
          row.style.display = 'flex';
          row.style.justifyContent = 'space-between';
          row.style.alignItems = 'center';
          row.style.gap = '8px';
          row.innerHTML = `<div style="flex:1">${k.masked} <span class="muted" style="font-size:12px;margin-left:8px">${k.created_at}</span></div>`;
          const btn = document.createElement('button');
          btn.textContent = '撤销';
          btn.className = 'danger';
          btn.addEventListener('click', async () => {
            if (!confirm('确定撤销此 key 吗？')) return;
            try {
              const r = await fetch(`/api/apikeys/${k.id}`, { method: 'DELETE', headers: getHeaders() });
              if (!r.ok) throw new Error(await r.text());
              await loadApiKeys();
            } catch (e) { alert(`撤销失败：${e.message}`); }
          });
          row.appendChild(btn);
          list.appendChild(row);
        });
      } catch (e) {
        console.debug('Could not load api keys', e.message);
      }
    }

    document.getElementById('genApiKey')?.addEventListener('click', async () => {
      try {
        const r = await fetch('/api/apikeys', { method: 'POST', headers: getHeaders() });
        if (!r.ok) throw new Error(await r.text());
        const j = await r.json();
        const out = document.getElementById('newApiKey');
        out.textContent = j.key || '';
        // refresh list
        await loadApiKeys();
        // clear visible key after 30s
        setTimeout(() => { out.textContent = ''; }, 30000);
      } catch (e) { alert(`生成失败：${e.message}`); }
    });

const state = {
  voices: [],
  voicesByLocale: new Map(),
  abort: null,
  currentItem: null,
  langQuery: '',
  langGroups: [],
  ttsCharsLimit: 500000,
};

const STYLE_ZH = {
  advertisement_upbeat: '广告（欢快）',
  affectionate: '深情',
  angry: '愤怒',
  assistant: '助理',
  calm: '平静',
  chat: '聊天',
  cheerful: '欢快',
  customerservice: '客服',
  depressed: '沮丧',
  disgruntled: '不满',
  documentary_narration: '纪录片旁白',
  embarrassed: '尴尬',
  empathetic: '共情',
  excited: '兴奋',
  fearful: '害怕',
  friendly: '友好',
  gentle: '温柔',
  hopeful: '充满希望',
  lyrical: '抒情',
  narration: '旁白',
  newscast: '新闻播报',
  newscast_casual: '新闻播报（随和）',
  newscast_formal: '新闻播报（正式）',
  poetry_reading: '诗歌朗诵',
  sad: '悲伤',
  serious: '严肃',
  shouting: '喊叫',
  terrified: '恐惧',
  unfriendly: '不友好',
  whispering: '耳语',
};

const STYLE_DESC_SHORT_ZH = {
  advertisement_upbeat: '带劲、有感染力',
  affectionate: '温柔深情',
  angry: '生气、冲突',
  assistant: '中性提示音',
  calm: '舒缓、稳定',
  chat: '自然口语',
  cheerful: '轻松明快',
  customerservice: '耐心礼貌',
  depressed: '低落',
  disgruntled: '抱怨、不满',
  documentary_narration: '纪录片口吻',
  embarrassed: '尴尬',
  empathetic: '共情安慰',
  excited: '兴奋',
  fearful: '紧张害怕',
  friendly: '亲切',
  gentle: '柔和',
  hopeful: '积极',
  lyrical: '抒情',
  narration: '讲述/旁白',
  newscast: '新闻口吻',
  newscast_casual: '新闻口吻（随和）',
  newscast_formal: '新闻口吻（正式）',
  poetry_reading: '朗诵腔',
  sad: '伤感',
  serious: '正式严肃',
  shouting: '大声',
  terrified: '恐惧',
  unfriendly: '冷淡',
  whispering: '轻声',
};

const STYLE_DESC_ZH = {
  advertisement_upbeat: '适合广告口播、带货、宣传文案，更有精气神。',
  affectionate: '适合情感类文案、告白、温柔叙述。',
  angry: '适合抱怨、争执、冲突台词。',
  assistant: '偏“智能助手/系统提示”的语气，清晰、中性。',
  calm: '适合讲解、冥想、舒缓叙述，整体更平稳。',
  chat: '更像日常聊天的口语表达。',
  cheerful: '轻松愉快、明亮的语气，适合娱乐/日常口播。',
  customerservice: '耐心礼貌的客服语气，适合售前售后。',
  depressed: '低落、无力的语气，适合情绪低谷场景。',
  disgruntled: '带点不耐烦/不满，适合吐槽类台词。',
  documentary_narration: '纪录片/旁白口吻，偏客观叙述。',
  embarrassed: '略尴尬、局促的感觉。',
  empathetic: '更有同理心，适合安慰/共情表达。',
  excited: '兴奋、期待，适合宣布/惊喜内容。',
  fearful: '紧张害怕，适合悬疑/惊悚台词。',
  friendly: '更亲切友好，适合服务/引导文案。',
  gentle: '更温柔轻声，适合睡前故事、抚慰类内容。',
  hopeful: '积极向上、有希望的语气。',
  lyrical: '偏抒情，有一点文学感。',
  narration: '标准旁白/讲述口吻。',
  newscast: '新闻播报腔，信息感更强。',
  newscast_casual: '新闻播报但更随和、口语化。',
  newscast_formal: '更正式的新闻播报腔。',
  poetry_reading: '诗歌/文章朗诵腔，节奏感更明显。',
  sad: '伤感、低沉，适合告别/回忆类文案。',
  serious: '正式严肃，适合公告/政策/严谨说明。',
  shouting: '提高音量与情绪强度，适合喊话/强调。',
  terrified: '更强烈的恐惧感，适合紧急/惊吓场景。',
  unfriendly: '冷淡、不太友好，适合对立/疏离台词。',
  whispering: '耳语/轻声，适合秘密/ASMR 风格。',
};

function normalizeStyleKey(s) {
  return String(s || '').trim().toLowerCase().replace(/[-\s]+/g, '_');
}

function styleLabel(s) {
  const raw = String(s || '').trim();
  if (!raw) return raw;
  const key = normalizeStyleKey(raw);
  const zh = STYLE_ZH[key];
  const short = STYLE_DESC_SHORT_ZH[key];
  return zh ? `${zh}（${raw}）${short ? ` - ${short}` : ''}` : raw;
}

function styleDesc(s) {
  const raw = String(s || '').trim();
  if (!raw) return '';
  const key = normalizeStyleKey(raw);
  return STYLE_DESC_ZH[key] || '';
}

function genderZh(gender) {
  const g = String(gender || '').toLowerCase();
  if (g === 'female') return '女';
  if (g === 'male') return '男';
  return '';
}

function localeLabel(locale) {
  const raw = String(locale || '').trim();
  if (!raw) return raw;
  try {
    if (typeof Intl !== 'undefined' && Intl.DisplayNames) {
      const parts = raw.split('-').filter(Boolean);
      const lang = parts[0] || '';
      const p2 = parts[1] || '';
      const p3 = parts[2] || '';

      const dnLang = new Intl.DisplayNames(['zh'], { type: 'language' });
      const dnReg = new Intl.DisplayNames(['zh'], { type: 'region' });
      const dnScript = new Intl.DisplayNames(['zh'], { type: 'script' });

      const langName = lang ? (dnLang.of(lang) || lang) : raw;

      const isScript = p2 && p2.length === 4;
      const script = isScript ? p2 : '';
      const region = isScript ? p3 : p2;

      const scriptName = script ? (dnScript.of(script) || script) : '';
      const regionName = region ? (dnReg.of(region) || region) : '';

      if (scriptName && regionName) return `${langName}（${scriptName}，${regionName}） (${raw})`;
      if (scriptName) return `${langName}（${scriptName}） (${raw})`;
      if (regionName) return `${langName}（${regionName}） (${raw})`;
      return `${langName} (${raw})`;
    }
  } catch (_) {}
  return raw;
}

let lastAudioUrl = null;

function beep(kind) {
  const off = document.getElementById('toggleBeep').checked;
  if (off) return;
  try {
    const ctx = new (window.AudioContext || window.webkitAudioContext)();
    const o = ctx.createOscillator();
    const g = ctx.createGain();
    o.type = 'sine';
    o.frequency.value = kind === 'ok' ? 880 : 220;
    g.gain.value = 0.02;
    o.connect(g);
    g.connect(ctx.destination);
    o.start();
    o.stop(ctx.currentTime + 0.08);
    o.onended = () => ctx.close().catch(() => {});
  } catch (_) {}
}

function updateCharCount() {
  const t = document.getElementById('ttsText').value || '';
  document.getElementById('charCount').textContent = `${t.length} 字符`;
  const limit = Number(state.ttsCharsLimit) || 0;
  document.getElementById('quotaHint').textContent = limit > 0
    ? `字数：${t.length}/${fmt(limit)}`
    : `字数：${t.length}`;
}

function _pad2(n) {
  return String(n).padStart(2, '0');
}

function _pad3(n) {
  return String(n).padStart(3, '0');
}

function formatSrtTime(seconds) {
  const s = Math.max(0, Number.isFinite(seconds) ? seconds : 0);
  const ms = Math.round((s % 1) * 1000);
  const total = Math.floor(s);
  const hh = Math.floor(total / 3600);
  const mm = Math.floor((total % 3600) / 60);
  const ss = total % 60;
  return `${_pad2(hh)}:${_pad2(mm)}:${_pad2(ss)},${_pad3(ms)}`;
}

async function getAudioDurationSeconds(url) {
  return await new Promise((resolve, reject) => {
    const audio = new Audio();
    audio.preload = 'metadata';
    audio.onloadedmetadata = () => {
      const d = Number(audio.duration);
      resolve(Number.isFinite(d) ? d : 0);
    };
    audio.onerror = () => reject(new Error('无法读取音频时长'));
    audio.src = url;
  });
}

function buildSingleCueSrt(text, durationSeconds) {
  const end = Math.max(0.2, Number.isFinite(durationSeconds) ? durationSeconds : 0);
  return `1\n${formatSrtTime(0)} --> ${formatSrtTime(end)}\n${String(text || '').trim()}\n`;
}

async function ensureSrtForItem(it) {
  if (!it || it.srtText) return;
  try {
    const duration = await getAudioDurationSeconds(it.url);
    it.srtText = buildSingleCueSrt(it.text, duration);
  } catch (_) {
    it.srtText = buildSingleCueSrt(it.text, 1.0);
  }
}

function downloadTextFile(filename, content) {
  const blob = new Blob([content], { type: 'text/plain;charset=utf-8' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 0);
}

function downloadBlobUrl(filename, url) {
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  a.remove();
}

function extFromOutputFormat(outputFormat) {
  const f = String(outputFormat || '').toLowerCase();
  if (f.startsWith('riff-') || f.includes('pcm')) return 'wav';
  if (f.includes('mp3')) return 'mp3';
  return 'mp3';
}

function setSliderPercent(id, outId) {
  const el = document.getElementById(id);
  const out = document.getElementById(outId);
  const sync = () => (out.textContent = `${el.value}%`);
  el.addEventListener('input', sync);
  sync();
}

function setSliderVolumeDb() {
  const el = document.getElementById('ttsVolume');
  const out = document.getElementById('volVal');
  const sync = () => {
    const v = Number(el.value);
    const db = (v / 100) * 12;
    const sign = db > 0 ? '+' : '';
    out.textContent = `${sign}${db.toFixed(1)} dB`;
  };
  el.addEventListener('input', sync);
  sync();
}

function setSliderStyleDegree() {
  const el = document.getElementById('ttsStyleDegree');
  const out = document.getElementById('styleDegreeVal');
  const sync = () => {
    const v = Number(el.value);
    out.textContent = v === 0 ? '0' : (v / 100).toFixed(2);
  };
  el.addEventListener('input', sync);
  sync();
}

setSliderPercent('ttsRate', 'rateVal');
setSliderPercent('ttsPitch', 'pitchVal');
setSliderVolumeDb();
setSliderStyleDegree();

document.getElementById('ttsText').addEventListener('input', updateCharCount);
updateCharCount();

function uniq(arr) {
  return Array.from(new Set(arr));
}

function setOptions(selectEl, options, value, includeEmpty) {
  selectEl.innerHTML = '';
  if (includeEmpty) {
    const opt = document.createElement('option');
    opt.value = '';
    opt.textContent = '（无）';
    selectEl.appendChild(opt);
  }
  for (const o of options) {
    const opt = document.createElement('option');
    opt.value = o.value;
    opt.textContent = o.label;
    selectEl.appendChild(opt);
  }
  if (value != null) selectEl.value = value;
}

async function loadVoices(locale) {
  const key = locale || '';
  if (state.voicesByLocale.has(key)) return state.voicesByLocale.get(key);
  const q = new URLSearchParams();
  if (locale) q.set('locale', locale);
  q.set('neural_only', 'true');
  const data = await fetchJson(`/api/tts/voices?${q.toString()}`);
  const voices = Array.isArray(data.voices) ? data.voices : [];
  state.voicesByLocale.set(key, voices);
  return voices;
}

function normalizeLocaleGroup(locale) {
  if (!locale) return 'unknown';
  const parts = String(locale).split('-');
  return parts.length >= 2 ? `${parts[0]}-${parts[1]}` : String(locale);
}

function getVoiceMetaByName(name) {
  for (const v of state.voices) {
    if (v && v.ShortName === name) return v;
  }
  return null;
}

function updateStyleRoleOptions() {
  const voiceName = document.getElementById('ttsVoice').value;
  const v = getVoiceMetaByName(voiceName);
  const styles = v && Array.isArray(v.StyleList) ? v.StyleList : [];
  const roles = v && Array.isArray(v.RolePlayList) ? v.RolePlayList : [];
  const styleSel = document.getElementById('ttsStyle');
  const roleSel = document.getElementById('ttsRole');
  const hint = document.getElementById('styleHint');

  if (!styles.length) {
    styleSel.innerHTML = '';
    const opt = document.createElement('option');
    opt.value = '';
    opt.textContent = '该语音不支持';
    styleSel.appendChild(opt);
    styleSel.disabled = true;
    if (hint) hint.textContent = '该语音不支持“情绪/风格”。';
  } else {
    styleSel.disabled = false;
    setOptions(
      styleSel,
      styles.map(s => ({ value: s, label: styleLabel(s) })),
      '',
      true
    );
  }

  if (!roles.length) {
    roleSel.innerHTML = '';
    const opt = document.createElement('option');
    opt.value = '';
    opt.textContent = '该语音不支持';
    roleSel.appendChild(opt);
    roleSel.disabled = true;
  } else {
    roleSel.disabled = false;
    setOptions(
      roleSel,
      roles.map(r => ({ value: r, label: r })),
      '',
      true
    );
  }

  document.getElementById('ttsStyleDegree').value = '0';
  setSliderStyleDegree();

  updateStyleHint();
}

function updateStyleHint() {
  const hint = document.getElementById('styleHint');
  const styleSel = document.getElementById('ttsStyle');
  if (!hint || !styleSel) return;

  if (styleSel.disabled) {
    hint.textContent = '该语音不支持“情绪/风格”。';
    return;
  }

  const v = String(styleSel.value || '').trim();
  if (!v) {
    hint.textContent = '不选则使用默认语气（无情绪）。';
    return;
  }

  const desc = styleDesc(v);
  hint.textContent = desc ? `说明：${desc}` : '说明：该情绪暂无预设说明（可直接试听确认效果）。';
}

async function initLanguagesAndVoices() {
  const voices = await loadVoices(null);
  state.voices = voices;

  const locales = uniq(voices.map(v => v && v.Locale).filter(Boolean)).sort();
  const groups = uniq(locales.map(normalizeLocaleGroup)).sort();
  state.langGroups = groups.map(g => ({ value: g, label: localeLabel(g) }));

  const langSel = document.getElementById('ttsLang');
  setOptions(langSel, state.langGroups, 'zh-CN', false);

  await refreshVoicesByLocale(langSel.value);
}

async function refreshVoicesByLocale(locale) {
  const voices = await loadVoices(locale);
  state.voices = voices;

  const voiceSel = document.getElementById('ttsVoice');
  const opts = voices
    .map(v => ({
      value: v.ShortName,
      label: `${genderZh(v.Gender) ? (genderZh(v.Gender) + ' ') : ''}${v.LocalName || v.DisplayName || v.ShortName} (${v.ShortName})`,
    }))
    .sort((a, b) => a.label.localeCompare(b.label, 'zh'));

  const current = voiceSel.value;
  const preferred = current && opts.some(o => o.value === current)
    ? current
    : (opts.find(o => o.value === 'zh-CN-XiaoxiaoNeural')
        ? 'zh-CN-XiaoxiaoNeural'
        : (opts[0] ? opts[0].value : ''));

  setOptions(voiceSel, opts, preferred, false);
  updateStyleRoleOptions();
}

document.getElementById('ttsLang').addEventListener('change', () => {
  refreshVoicesByLocale(document.getElementById('ttsLang').value).catch(e => alert(`加载语音失败：${e.message}`));
});

document.getElementById('langSearch')?.addEventListener('input', () => {
  const q = String(document.getElementById('langSearch')?.value || '').trim().toLowerCase();
  state.langQuery = q;
  const langSel = document.getElementById('ttsLang');
  const current = langSel.value;
  const filtered = q
    ? state.langGroups.filter(x => `${x.value} ${x.label}`.toLowerCase().includes(q))
    : state.langGroups;
  const preferred = current && filtered.some(x => x.value === current)
    ? current
    : (filtered[0] ? filtered[0].value : '');
  setOptions(langSel, filtered, preferred, false);
  refreshVoicesByLocale(langSel.value).catch(() => {});
});

document.getElementById('ttsVoice').addEventListener('change', () => {
  updateStyleRoleOptions();
});

document.getElementById('ttsStyle')?.addEventListener('change', () => {
  updateStyleHint();
});

function currentParams() {
  const styleDegreeRaw = Number(document.getElementById('ttsStyleDegree').value);
  const styleDegree = styleDegreeRaw === 0 ? 0 : styleDegreeRaw / 100;
  return {
    voice: document.getElementById('ttsVoice').value,
    output_format: document.getElementById('ttsFormat').value,
    lang: document.getElementById('ttsLang').value,
    style: document.getElementById('ttsStyle').value,
    role: document.getElementById('ttsRole').value,
    style_degree: styleDegree,
    rate: Number(document.getElementById('ttsRate').value),
    pitch: Number(document.getElementById('ttsPitch').value),
    volume: Number(document.getElementById('ttsVolume').value),
    pause_ms: Number(document.getElementById('ttsPauseMs')?.value || 0),
  };
}

async function synthesizeOne(text, params, signal) {
  const fd = new FormData();
  fd.append('text', text);
  fd.append('voice', params.voice);
  fd.append('output_format', params.output_format);
  fd.append('lang', params.lang);
  fd.append('style', params.style || '');
  fd.append('role', params.role || '');
  fd.append('style_degree', String(params.style_degree || 0));
  fd.append('rate', String(params.rate || 0));
  fd.append('pitch', String(params.pitch || 0));
  fd.append('volume', String(params.volume || 0));
  fd.append('pause_ms', String(params.pause_ms || 0));

  const r = await fetch('/api/tts/synthesize', { method: 'POST', body: fd, signal, headers: getHeaders() });
  if (!r.ok) throw new Error(await r.text());
  return await r.blob();
}

function setCurrentItem(it) {
  state.currentItem = it;
  const btnDown = document.getElementById('btnDownload');
  const btnSrt = document.getElementById('btnDownloadSrt');
  if (btnDown) btnDown.disabled = !it;
  if (btnSrt) btnSrt.disabled = !it;

  const btnGen = document.getElementById('btnGenSrt');
  if (btnGen) {
    btnGen.disabled = false;
    btnGen.textContent = '生成字幕（SRT）';
  }
}

async function runSingleSynthesis() {
  const raw = document.getElementById('ttsText').value;
  const text = String(raw || '').trim();
  if (!text) return alert('请输入文本');

  if (state.abort) state.abort.abort();
  state.abort = new AbortController();

  const params = currentParams();
  const blob = await synthesizeOne(text, params, state.abort.signal);

  const url = URL.createObjectURL(blob);
  const ts = Date.now();
  const base = `tts_${ts}`;
  const ext = extFromOutputFormat(params.output_format);
  const filename = `${base}.${ext}`;
  const srtFilename = `${base}.srt`;
  const item = {
    text,
    url,
    filename,
    srtFilename,
    srtText: '',
    label: `${params.voice} | ${params.lang}`,
  };

  const audio = document.getElementById('ttsAudio');
  audio.src = url;

  if (lastAudioUrl) URL.revokeObjectURL(lastAudioUrl);
  lastAudioUrl = url;

  setCurrentItem(item);

  if (document.getElementById('toggleAutoDownload').checked) {
    downloadBlobUrl(filename, url);
  }

  beep('ok');
  await refreshUsage();
}

document.getElementById('ttsBtn').addEventListener('click', () => {
  runSingleSynthesis().catch(e => {
    beep('err');
    alert(`生成失败：${e.message}`);
  });
});

document.getElementById('ttsStop').addEventListener('click', () => {
  if (state.abort) state.abort.abort();
  const audio = document.getElementById('ttsAudio');
  audio.pause();
  audio.currentTime = 0;
});

document.getElementById('btnPreview').addEventListener('click', () => {
  const old = document.getElementById('ttsText').value;
  const sample = old.trim() ? old.trim().slice(0, 60) : '你好，我是 Azure Speech。';
  const params = currentParams();
  if (state.abort) state.abort.abort();
  state.abort = new AbortController();
  synthesizeOne(sample, params, state.abort.signal)
    .then(blob => {
      const url = URL.createObjectURL(blob);
      const audio = document.getElementById('ttsAudio');
      audio.src = url;
      audio.play().catch(() => {});
      beep('ok');
    })
    .catch(e => {
      beep('err');
      alert(`试听失败：${e.message}`);
    });
});

document.getElementById('btnClear').addEventListener('click', () => {
  document.getElementById('ttsText').value = '';
  updateCharCount();
  setCurrentItem(null);
});

document.getElementById('btnFormat').addEventListener('click', () => {
  const t = String(document.getElementById('ttsText').value || '');
  const lines = t
    .split(/\r?\n/)
    .map(s => s.trim())
    .filter(Boolean);
  document.getElementById('ttsText').value = lines.join('\n');
  updateCharCount();
});

const dlg = document.getElementById('replaceDlg');
document.getElementById('btnReplace').addEventListener('click', () => {
  dlg.showModal();
});
document.getElementById('btnReplaceCancel').addEventListener('click', () => {
  dlg.close();
});

document.getElementById('btnDownload')?.addEventListener('click', () => {
  const it = state.currentItem;
  if (!it) return alert('尚未生成音频');
  downloadBlobUrl(it.filename, it.url);
});

document.getElementById('btnDownloadSrt')?.addEventListener('click', async () => {
  const it = state.currentItem;
  if (!it) return alert('尚未生成音频');
  if (!it.srtText) await ensureSrtForItem(it);
  if (!it.srtText) return alert('字幕尚未生成，请稍后再试');
  downloadTextFile(it.srtFilename, it.srtText);
});
document.getElementById('btnReplaceApply').addEventListener('click', () => {
  const find = document.getElementById('findText').value || '';
  const rep = document.getElementById('replaceText').value || '';
  if (!find) return;
  const t = String(document.getElementById('ttsText').value || '');
  document.getElementById('ttsText').value = t.split(find).join(rep);
  updateCharCount();
  dlg.close();
});

(async function init() {
  try {
    const apiKeyInput = document.getElementById('apiKey');
    if (apiKeyInput) {
      const savedKey = localStorage.getItem('tts_api_key');
      if (savedKey) apiKeyInput.value = savedKey;
      apiKeyInput.addEventListener('input', () => {
        localStorage.setItem('tts_api_key', apiKeyInput.value);
      });
    }

    await refreshUsage();
    await initLanguagesAndVoices();
  } catch (e) {
    console.error('Initialization failed:', e);
    alert(`应用初始化失败：${e.message}`);
  }
})();

document.getElementById('btnGenSrt').addEventListener('click', () => {
  const btn = document.getElementById('btnGenSrt');
  const it = state.currentItem;
  if (!it) return alert('请先生成一条音频');
  btn.disabled = true;
  const oldText = btn.textContent;
  btn.textContent = '正在生成字幕...';
  Promise.resolve()
    .then(async () => {
      await ensureSrtForItem(it);
      if (!it.srtText) throw new Error('字幕生成失败');
      downloadTextFile(it.srtFilename, it.srtText);
    })
    .then(() => {
      btn.textContent = '字幕已下载';
      setTimeout(() => {
        btn.disabled = false;
        btn.textContent = oldText;
      }, 2000);
    })
    .catch(e => {
      btn.disabled = false;
      btn.textContent = oldText;
      alert(`生成字幕失败：${e.message}`);
    });
});
