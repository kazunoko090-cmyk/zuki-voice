// Zuki Voice — Worker 入口（app層）
// core（ルール）と adapters（AI接続）を組み合わせて API にする。
// APIの戻り値は必ず同じ封筒： { ok:true, ... } か { ok:false, error:"..." }

import {
  cleanFillers,
  polishSystemPrompt,
  dictToHint,
  normalizeWav16,
  isPlausiblePolish,
  LIMITS,
} from "./core/cleanup.js";
import {
  polishWithClaude,
  polishWithWorkersAI,
  transcribeWithWhisper,
} from "./adapters/ai.js";

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname.startsWith("/api/")) {
      return handleApi(request, env, url);
    }

    // それ以外は public/ の静的ファイル（landing / app）
    return env.ASSETS.fetch(request);
  },
};

async function handleApi(request, env, url) {
  if (request.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders() });
  }
  if (request.method !== "POST") {
    return json({ ok: false, error: "POST only" }, 405);
  }

  // 合言葉（APP_PASSWORD）を設定している場合だけチェックする
  if (env.APP_PASSWORD) {
    const k = request.headers.get("x-app-key") || url.searchParams.get("k") || "";
    if (k !== env.APP_PASSWORD) {
      return json({ ok: false, error: "unauthorized" }, 401);
    }
  }

  let body;
  try {
    body = await request.json();
  } catch (e) {
    return json({ ok: false, error: "bad json" }, 400);
  }

  if (url.pathname === "/api/transcribe") return apiTranscribe(env, body);
  if (url.pathname === "/api/polish") return apiPolish(env, body);
  return json({ ok: false, error: "not found" }, 404);
}

// ---- 文字起こし：音声(base64) → テキスト ----
async function apiTranscribe(env, body) {
  const audio = String((body && body.audio) || "");
  if (!audio) return json({ ok: false, error: "no audio" }, 400);
  // base64は実データの約4/3倍
  if (audio.length > (LIMITS.maxAudioBytes * 4) / 3) {
    return json({ ok: false, error: "audio too large" }, 413);
  }
  const hint = dictToHint(body && body.dict);
  const text = await transcribeWithWhisper(env, louder(audio), hint);
  if (text === null) {
    return json({ ok: false, error: "transcribe failed" }, 502);
  }
  return json({ ok: true, text });
}

// ---- 整形：テキスト → フィラー除去・整った文章 ----
async function apiPolish(env, body) {
  const text = String((body && body.text) || "").slice(0, LIMITS.maxPolishChars);
  if (!text.trim()) return json({ ok: false, error: "no text" }, 400);
  const style = String((body && body.style) || "clean");
  const system = polishSystemPrompt(style, body && body.dict);

  // Claude → Workers AI → ルールベース の順に試す（整形の範囲を超えた長文は採用しない）
  const ok = (s) => (s !== null && isPlausiblePolish(text, s, style) ? s : null);
  let out = ok(await polishWithClaude(env, system, text));
  let engine = "claude";
  if (out === null) {
    out = ok(await polishWithWorkersAI(env, system, text));
    engine = "workers-ai";
  }
  if (out === null) {
    const r = cleanFillers(text);
    out = r.text;
    engine = "rules";
  }
  return json({ ok: true, text: out, engine });
}

// base64 の WAV を音量補正して base64 に戻す（WAV以外はそのまま）
function louder(b64) {
  try {
    const bin = atob(b64);
    const bytes = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    const out = normalizeWav16(bytes);
    if (out === bytes) return b64;
    let s = "";
    for (let i = 0; i < out.length; i += 0x8000) {
      s += String.fromCharCode.apply(null, out.subarray(i, i + 0x8000));
    }
    return btoa(s);
  } catch (e) {
    return b64;
  }
}

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", ...corsHeaders() },
  });
}

function corsHeaders() {
  return {
    "access-control-allow-origin": "*",
    "access-control-allow-methods": "POST, OPTIONS",
    "access-control-allow-headers": "content-type, x-app-key",
  };
}
