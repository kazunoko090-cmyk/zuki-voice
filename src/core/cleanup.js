// core/cleanup.js — 業務ルール（純粋関数だけ。fetch・env・D1を書かない）
//
// 音声の文字起こしからフィラー・繰り返しを取り除くルールベース整形。
// AI（Claude / Workers AI）が使えないときの最終フォールバック。
// 「意味を変えない」が最優先なので、削るのは確実にフィラーと言えるものだけ。

// 単体で出てきたら削ってよい日本語フィラー（前後の読点・空白ごと消す）
const JA_FILLERS = [
  "えーっと", "えーと", "ええっと", "ええと", "えっとー", "えっと",
  "あのー", "あのう", "あのさー", "あのですね",
  "うーんと", "うんと", "んーと", "んっと",
  "えー", "ええー", "うーん", "んー",
  "まぁー", "まあー",
  "そのー", "そのう",
  "なんかこう", "なんていうか", "なんだろう", "何だろう",
];

// 英語のフィラー（混ざることがある）
const EN_FILLERS = ["um", "uh", "er", "ah", "you know", "like,"];

/**
 * ルールベースでフィラーと単純な繰り返しを除去する。
 * @param {string} text 文字起こしテキスト
 * @returns {{ text: string, removed: number }} 整形後テキストと削除した個数
 */
export function cleanFillers(text) {
  let t = String(text || "");
  let removed = 0;

  // 長いものから順に消す（「えーっと」より先に「えー」を消すと食い違うため）
  const fillers = [...JA_FILLERS].sort((a, b) => b.length - a.length);
  for (const f of fillers) {
    // フィラー＋直後の読点/空白をまとめて消す。語中にはマッチさせない
    const re = new RegExp(`(^|[、。\\s])${escapeRe(f)}[、。]?\\s*`, "g");
    t = t.replace(re, (m, pre) => {
      removed++;
      return pre === "" ? "" : pre;
    });
  }
  for (const f of EN_FILLERS) {
    const re = new RegExp(`(^|[\\s,])${escapeRe(f)}[\\s,]+`, "gi");
    t = t.replace(re, (m, pre) => {
      removed++;
      return pre || " ";
    });
  }

  // 同じ語句の直後の繰り返し（「これはこれは」「本当に本当に」）を1つにする
  t = t.replace(/([ぁ-んァ-ヶ一-龠a-zA-Z0-9]{2,8})、?\1/g, (m, w) => {
    removed++;
    return w;
  });

  // 読点の連続・余分な空白を整える
  t = t
    .replace(/、{2,}/g, "、")
    .replace(/(^|。)、/g, "$1")
    .replace(/[ \t]{2,}/g, " ")
    .replace(/^[、\s]+/, "")
    .trim();

  return { text: t, removed };
}

function escapeRe(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/**
 * 個人辞書をプロンプト用の文字列にする。
 * @param {Array<{r:string,w?:string}>} dict r=正しい表記, w=読み・よくある誤変換（任意）
 */
export function dictToPromptLines(dict) {
  if (!Array.isArray(dict)) return "";
  const lines = dict
    .slice(0, LIMITS.maxDictEntries)
    .map((d) => {
      const r = String((d && d.r) || "").trim().slice(0, 40);
      const w = String((d && d.w) || "").trim().slice(0, 40);
      if (!r) return "";
      return w ? `「${w}」→「${r}」` : `「${r}」`;
    })
    .filter(Boolean);
  return lines.join("、");
}

/**
 * 個人辞書をWhisperのヒント（initial_prompt）用の文字列にする。
 */
export function dictToHint(dict) {
  if (!Array.isArray(dict)) return "";
  return dict
    .slice(0, LIMITS.maxDictEntries)
    .map((d) => String((d && d.r) || "").trim())
    .filter(Boolean)
    .join("、")
    .slice(0, 600);
}

/**
 * スタイルごとのAI整形プロンプトを返す（AI呼び出し自体はadapters側の仕事）。
 * @param {string} style "clean" | "mail" | "chat" | "bullets"
 * @param {Array<{r:string,w?:string}>} [dict] 個人辞書
 */
export function polishSystemPrompt(style, dict) {
  const base =
    "あなたは音声入力の文字起こしを整える編集者。" +
    "フィラー（「えー」「あの」「えっと」「うーん」など）と無駄な繰り返しを削除し、" +
    "途中で言い直した箇所は最終的に意図した内容だけを残す。" +
    "意味・事実・数字・固有名詞は絶対に変えない。勝手に情報を足さない。" +
    "自然な書き言葉に整え、適切に句読点と改行を入れる。" +
    "前置きや説明は書かず、整えた本文だけを返す。";
  const byStyle = {
    clean: "",
    mail: "出力は丁寧なビジネスメールの本文にする（宛名と署名は書かない。です・ます調）。",
    chat: "出力は短く親しみやすいチャットメッセージにする（固すぎない自然な口調）。",
    bullets: "出力は要点を整理した箇条書きにする（記号は「・」、必要なら短い見出しも可）。",
  };
  const dictLines = dictToPromptLines(dict);
  const dictPart = dictLines
    ? "ユーザーの個人辞書。固有名詞・専門用語は必ずこの表記に直す（「誤」→「正」、単独表記はそのまま使う）：" +
      dictLines +
      "。"
    : "";
  return base + dictPart + (byStyle[style] || "");
}

/** 入力テキストの上限などの契約 */
export const LIMITS = {
  maxPolishChars: 8000, // 1回の整形に渡す最大文字数
  maxAudioBytes: 24 * 1024 * 1024, // 音声の最大サイズ（約24MB）
  maxDictEntries: 100, // 個人辞書の最大登録数
};
