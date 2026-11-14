// ==UserScript==
// @name         Copy Best Stream (HLS/DASH) on Right-Click
// @namespace    video.stream.copy
// @version      2.2.0
// @description  Right-click a <video> to copy the highest-quality HLS/DASH URL seen on the page (or the active one). Ctrl+Right-Click copies raw without upgrading.
// @match        *://*/*
// @run-at       document-start
// @grant        GM_setClipboard
// @updateURL    https://raw.githubusercontent.com/frcooper/qvcp/main/video-stream-capture.user.js
// @downloadURL  https://raw.githubusercontent.com/frcooper/qvcp/main/video-stream-capture.user.js
// ==/UserScript==
(() => {
  'use strict';

  // ---------- prefs ----------
  // Minimal re-encode bias: prefer H.264 for remux, then VP9, then HEVC, then AV1.
  const CODEC_ORDER = ['h264', 'avc1', 'vp9', 'hvc1', 'hev1', 'av01'];
  const PREFER_RESOLUTION = true;
  const RAW_MODIFIER = 'ctrlKey';
  const TOAST_MS = 1600;
  const BY_ORIGIN = true;

  // ---------- state ----------
  const bucketMap = new Map(); // origin => { latestMaster, latestMedia, latestMPD }
  const getBucket = () => {
    if (!BY_ORIGIN) return bucketMap.get('') || (bucketMap.set('', {}), bucketMap.get(''));
    const k = location.origin;
    if (!bucketMap.has(k)) bucketMap.set(k, {});
    return bucketMap.get(k);
  };

  const isHLS = (url) => {
    try { const u = new URL(url, location.href); return /\.m3u8($|\?)/i.test(u.pathname + u.search); }
    catch { return false; }
  };
  const isDASH = (url) => {
    try { const u = new URL(url, location.href); return /\.mpd($|\?)/i.test(u.pathname + u.search); }
    catch { return false; }
  };
  const absURL = (url, base = location.href) => {
    try { return new URL(url, base).href; } catch { return null; }
  };

  const toast = (msg, ok = true) => {
    const el = document.createElement('div');
    el.textContent = msg;
    el.style.cssText = `
      position: fixed; z-index: 2147483647; left: 50%; transform: translateX(-50%);
      bottom: 24px; padding: 10px 14px; border-radius: 10px;
      font: 12px/1.2 system-ui,-apple-system,Segoe UI,Roboto,Ubuntu,sans-serif;
      color: ${ok ? '#0b1' : '#b00'}; background: ${ok ? 'rgba(230,255,235,.95)' : 'rgba(255,235,230,.95)'};
      box-shadow: 0 6px 20px rgba(0,0,0,.18); border: 1px solid rgba(0,0,0,.1);
      white-space: pre-wrap; max-width: 90vw; word-break: break-all;
    `;
    document.documentElement.appendChild(el);
    setTimeout(() => el.remove(), TOAST_MS);
  };

  const copyText = async (text) => {
    try {
      if (typeof GM_setClipboard === 'function') {
        GM_setClipboard(text, { type: 'text', mimetype: 'text/plain' });
        return true;
      }
    } catch {}
    try {
      if (navigator.clipboard?.writeText) {
        await navigator.clipboard.writeText(text);
        return true;
      }
    } catch {}
    return false;
  };

  // ---------- HLS/DASH parsing ----------
  const pickBestFromHLSMaster = (masterText, masterURL) => {
    const lines = masterText.split(/\r?\n/);
    const variants = [];
    // Audio groups carried as separate playlists. A variant that references one
    // has no audio of its own, so copying the variant URL would drop the sound.
    const separateAudio = new Set();
    for (let i = 0; i < lines.length; i++) {
      const L = lines[i];
      if (L.startsWith('#EXT-X-MEDIA:')) {
        const attrs = L.slice(13);
        const group = /GROUP-ID="([^"]+)"/i.exec(attrs)?.[1];
        if (group && /TYPE=AUDIO/i.test(attrs) && /URI="/i.test(attrs)) separateAudio.add(group);
        continue;
      }
      if (L.startsWith('#EXT-X-STREAM-INF:')) {
        const info = L.slice(18);
        const next = (lines[i + 1] || '').trim();
        const bw = /BANDWIDTH=(\d+)/i.exec(info)?.[1];
        const res = /RESOLUTION=(\d+)x(\d+)/i.exec(info);
        const codecs = /CODECS="([^"]+)"/i.exec(info)?.[1] || '';
        const audio = /AUDIO="([^"]+)"/i.exec(info)?.[1] || '';
        const url = absURL(next, masterURL);
        if (!url) continue;
        variants.push({
          url,
          bw: bw ? parseInt(bw, 10) : 0,
          w: res ? parseInt(res[1], 10) : 0,
          h: res ? parseInt(res[2], 10) : 0,
          codecs: codecs.toLowerCase(),
          audio,
        });
      }
    }
    if (!variants.length) return null;

    const scoreCodec = (cstr) => {
      const idx = CODEC_ORDER.findIndex(c => cstr.includes(c));
      return idx < 0 ? CODEC_ORDER.length : idx;
    };
    variants.forEach(v => {
      const codecRank = scoreCodec(v.codecs);
      const resScore = v.w * v.h;
      v._score =
        (PREFER_RESOLUTION ? resScore : v.bw) * 1e6
        - codecRank * 1e9
        + (PREFER_RESOLUTION ? v.bw : resScore);
    });
    variants.sort((a, b) => b._score - a._score);
    // Keep the master so the downloader can mux the video and audio playlists together.
    if (variants[0].audio && separateAudio.has(variants[0].audio)) return absURL(masterURL);
    return variants[0].url;
  };

  const pickBestFromMPD = (xmlText, mpdURL) => {
    let doc;
    try { doc = new DOMParser().parseFromString(xmlText, 'application/xml'); } catch { return absURL(mpdURL); }
    if (doc.querySelector('parsererror')) return absURL(mpdURL);

    const reps = [];
    doc.querySelectorAll('AdaptationSet[mimeType*="video"], AdaptationSet[contentType="video"]').forEach(as => {
      as.querySelectorAll('Representation').forEach(r => {
        const bw = parseInt(r.getAttribute('bandwidth') || '0', 10);
        const w = parseInt(r.getAttribute('width') || '0', 10);
        const h = parseInt(r.getAttribute('height') || '0', 10);
        const codecs = (r.getAttribute('codecs') || '').toLowerCase();
        // For copying, returning the MPD URL is sufficient; the player selects segments.
        reps.push({ bw, w, h, codecs, url: absURL(mpdURL) });
      });
    });
    if (!reps.length) return absURL(mpdURL);

    const scoreCodec = (cstr) => {
      const idx = CODEC_ORDER.findIndex(c => cstr.includes(c));
      return idx < 0 ? CODEC_ORDER.length : idx;
    };
    reps.forEach(v => {
      const codecRank = scoreCodec(v.codecs);
      const resScore = v.w * v.h;
      v._score =
        (PREFER_RESOLUTION ? resScore : v.bw) * 1e6
        - codecRank * 1e9
        + (PREFER_RESOLUTION ? v.bw : resScore);
    });
    reps.sort((a, b) => b._score - a._score);
    return reps[0].url;
  };

  const fetchText = async (url) => {
    try {
      const r = await fetch(url, { credentials: 'include' });
      if (!r.ok) return null;
      return await r.text();
    } catch { return null; }
  };

  const upgradeToBest = async (url) => {
    if (!url) return null;
    const u = absURL(url);
    if (!u) return null;

    if (isHLS(u)) {
      const text = await fetchText(u);
      if (text && /#EXT-X-STREAM-INF:/i.test(text)) {
        return pickBestFromHLSMaster(text, u) || u;
      }
      return u; // media playlist
    }

    if (isDASH(u)) {
      const text = await fetchText(u);
      if (text) return pickBestFromMPD(text, u) || u;
      return u;
    }

    return u;
  };

  const extractFromVideo = (video) => {
    if (!video) return null;
    const urls = [];
    if (video.currentSrc) urls.push(video.currentSrc);
    if (video.src) urls.push(video.src);
    video.querySelectorAll('source[src]').forEach(s => urls.push(s.getAttribute('src')));
    for (const u of urls) {
      if (isHLS(u) || isDASH(u)) return absURL(u);
    }
    return null;
  };

  // ---------- page-context instrumentation ----------
  // Inject a small script into the page context to hook fetch/XHR reliably.
  const inject = () => {
    const code = `
      (function(){
        const isHLS = u => { try { const x = new URL(u, location.href); return /\\.m3u8($|\\?)/i.test(x.pathname + x.search);} catch {return false;} };
        const isDASH = u => { try { const x = new URL(u, location.href); return /\\.mpd($|\\?)/i.test(x.pathname + x.search);} catch {return false;} };
        const remember = url => {
          try {
            if (!(isHLS(url) || isDASH(url))) return;
            window.postMessage({__video_stream_seen__: true, url: new URL(url, location.href).href}, '*');
          } catch {}
        };

        // fetch
        const of = window.fetch;
        if (typeof of === 'function') {
          window.fetch = function(input, init) {
            try { remember(typeof input === 'string' ? input : input && input.url); } catch {}
            return of.apply(this, arguments);
          };
          try { Object.defineProperty(window.fetch, 'toString', {value: ()=>'function fetch() { [native code] }'}); } catch {}
        }

        // XHR
        const ox = XMLHttpRequest.prototype.open;
        XMLHttpRequest.prototype.open = function(method, url) {
          try { remember(url); } catch {}
          return ox.apply(this, arguments);
        };
        try { Object.defineProperty(XMLHttpRequest.prototype.open, 'toString', {value: ()=>'function open() { [native code] }'}); } catch {}
      })();
    `;
    const s = document.createElement('script');
    s.textContent = code;
    (document.head || document.documentElement).appendChild(s);
    s.remove();
  };
  inject();

  // Receive URLs from page
  const pageSeen = new Set();
  window.addEventListener('message', (ev) => {
    const data = ev?.data;
    if (!data || !data.__video_stream_seen__) return;
    const url = data.url;
    if (!url || pageSeen.has(url)) return;
    pageSeen.add(url);
    const b = getBucket();
    if (isHLS(url)) {
      // Heuristic: anything with "master" or "index" is likely the master list.
      if (/master|index|playlist/i.test(new URL(url).pathname)) b.latestMaster = url;
      else b.latestMaster ??= /\\.m3u8$/i.test(new URL(url).pathname) ? url : b.latestMaster;
      b.latestMedia = url; // keep the last-seen media too
    } else if (isDASH(url)) {
      b.latestMPD = url;
    }
  });

  // Also track attribute changes for static <video>
  const mo = new MutationObserver((muts) => {
    const b = getBucket();
    for (const m of muts) {
      if (m.type === 'attributes' && m.target?.nodeName === 'VIDEO' && m.attributeName === 'src') {
        const u = m.target.getAttribute('src');
        if (isHLS(u)) b.latestMedia = absURL(u);
        if (isDASH(u)) b.latestMPD = absURL(u);
      }
    }
  });
  mo.observe(document.documentElement, { subtree: true, attributes: true, attributeFilter: ['src'] });

  // ---------- context menu ----------
  const onContextMenu = async (ev) => {
    const video = ev.target?.closest?.('video');
    if (!video) return;

    const rawMode = !!ev[RAW_MODIFIER];
    const b = getBucket();

    // prefer URL bound to this video, else master/MPD, else media
    const vUrl = extractFromVideo(video);
    const pick = vUrl || b.latestMaster || b.latestMPD || b.latestMedia;
    if (!pick) { toast('No HLS/DASH URL found on this page/video', false); return; }

    const out = rawMode ? pick : (await upgradeToBest(pick)) || pick;
    const ok = await copyText(out);
    toast(ok ? (rawMode ? `copied (raw):\n${out}` : `copied (best):\n${out}`) : 'Failed to copy URL (clipboard blocked)', ok);
  };

  const attach = () => window.addEventListener('contextmenu', onContextMenu, true);
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', attach, { once: true });
  } else {
    attach();
  }
})();
