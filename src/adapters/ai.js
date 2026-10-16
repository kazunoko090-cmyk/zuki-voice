// adapters/ai.js — 外部AIへの実際の接続（Claude API / Workers AI）
// ここには「どう繋ぐか」だけを書く。何を頼むか（プロンプト）は core が決める。

/**
 * Claude Haiku で整形する。鍵が無い・失敗したら null を返す（上位でフォールバック）。
 * @returns {Promise<string|null>}
 */
export async function polishWithClaude(env, system, text) {
  if (!env.ANTHROPIC_API_KEY) return null;
  try {
    const r = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "x-api-key": env.ANTHROPIC_API_KEY,
        "anthropic-version": "2023-06-01",
        "content-type": "application/json",
      },
      body: JSON.stringify({
        model: "claude-haiku-4-5",
        max_tokens: 3000,
        system,
        messages: [{ role: "user", content: text }],
      }),
    });
    if (!r.ok) return null;
    const d = await r.json();
    if (d.stop_reason === "refusal") return null;
    const out = (d.content || [])
      .filter((x) => x.type === "text")
      .map((x) => x.text)
      .join("")
      .trim();
    return out || null;
  } catch (e) {
    return null;
  }
}

/**
 * Workers AI のLLMで整形する（Claudeの鍵が無いときの代打）。失敗したら null。
 * @returns {Promise<string|null>}
 */
export async function polishWithWorkersAI(env, system, text) {
  if (!env.AI) return null;
  try {
    const d = await env.AI.run("@cf/meta/llama-3.3-70b-instruct-fp8-fast", {
      messages: [
        { role: "system", content: system },
        { role: "user", content: text },
      ],
      max_tokens: 2000,
    });
    const out = String((d && d.response) || "").trim();
    return out || null;
  } catch (e) {
    return null;
  }
}

/**
 * Workers AI の Whisper で文字起こしする。
 * @param {string} audioBase64 音声データ（base64）
 * @param {string} [hint] 個人辞書の単語ヒント（initial_promptで認識をその表記に寄せる）
 * @returns {Promise<string|null>} 文字起こしテキスト。失敗したら null
 */
export async function transcribeWithWhisper(env, audioBase64, hint) {
  if (!env.AI) return null;
  // まず新しい turbo モデル、ダメなら旧 whisper にフォールバック
  try {
    // 自動判定だと小声の日本語を英語と誤認することがあるので、日本語に固定する
    const d = await env.AI.run("@cf/openai/whisper-large-v3-turbo", {
      audio: audioBase64,
      language: "ja",
      initial_prompt: "以下は日本語の音声です。" + (hint ? hint : ""),
    });
    const t = String((d && d.text) || "").trim();
    if (t) return t;
  } catch (e) {
    /* fall through */
  }
  try {
    const bytes = base64ToBytes(audioBase64);
    const d = await env.AI.run("@cf/openai/whisper", { audio: [...bytes] });
    const t = String((d && d.text) || "").trim();
    return t || null;
  } catch (e) {
    return null;
  }
}

function base64ToBytes(b64) {
  const bin = atob(b64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return bytes;
}
