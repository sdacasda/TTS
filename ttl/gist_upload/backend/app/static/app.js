async function fetchJson(url) {
  const r = await fetch(url);
  if (!r.ok) throw new Error(await r.text());
  return await r.json();
}

function fmt(n) {
  return new Intl.NumberFormat().format(n);
}

async function refreshUsage() {
  const u = await fetchJson('/api/usage/summary');
  const el = document.getElementById('usage');
  el.innerHTML = `
    <div><b>Month</b>: ${u.month}</div>
    <div style="margin-top:8px;"><b>STT</b>: used ${fmt(u.used.stt_seconds)}s / limit ${fmt(u.limits.stt_seconds)}s / remaining ${fmt(u.remaining.stt_seconds)}s</div>
    <div><b>TTS</b>: used ${fmt(u.used.tts_chars)} chars / limit ${fmt(u.limits.tts_chars)} / remaining ${fmt(u.remaining.tts_chars)}</div>
    <div><b>Pron</b>: used ${fmt(u.used.pron_seconds)}s / limit ${fmt(u.limits.pron_seconds)}s / remaining ${fmt(u.remaining.pron_seconds)}s</div>
  `;
}

document.getElementById('refreshUsage').addEventListener('click', () => {
  refreshUsage().catch(e => alert(e.message));
});

document.getElementById('ttsBtn').addEventListener('click', async () => {
  const fd = new FormData();
  fd.append('text', document.getElementById('ttsText').value);
  fd.append('voice', document.getElementById('ttsVoice').value);
  fd.append('output_format', document.getElementById('ttsFormat').value);

  const r = await fetch('/api/tts/synthesize', { method: 'POST', body: fd });
  if (!r.ok) {
    alert(await r.text());
    return;
  }
  const blob = await r.blob();
  const url = URL.createObjectURL(blob);
  const audio = document.getElementById('ttsAudio');
  audio.src = url;
  audio.play().catch(() => {});
  await refreshUsage();
});

document.getElementById('sttBtn').addEventListener('click', async () => {
  const f = document.getElementById('sttFile').files[0];
  if (!f) return alert('Select a WAV file');

  const fd = new FormData();
  fd.append('audio', f);
  fd.append('language', document.getElementById('sttLang').value);
  fd.append('seconds', document.getElementById('sttSeconds').value || '0');

  const r = await fetch('/api/stt/recognize', { method: 'POST', body: fd });
  const out = document.getElementById('sttOut');
  out.textContent = r.ok ? JSON.stringify(await r.json(), null, 2) : await r.text();
  await refreshUsage();
});

document.getElementById('paBtn').addEventListener('click', async () => {
  const f = document.getElementById('paFile').files[0];
  if (!f) return alert('Select a WAV file');

  const fd = new FormData();
  fd.append('audio', f);
  fd.append('language', document.getElementById('paLang').value);
  fd.append('reference_text', document.getElementById('paRef').value);
  fd.append('seconds', document.getElementById('paSeconds').value || '0');

  const r = await fetch('/api/pronunciation/assess', { method: 'POST', body: fd });
  const out = document.getElementById('paOut');
  out.textContent = r.ok ? JSON.stringify(await r.json(), null, 2) : await r.text();
  await refreshUsage();
});

refreshUsage().catch(() => {});
