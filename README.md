# Zuki Voice 🎙️

**話す、書かない。** — 自然に話すだけで、AIがフィラー（「えーと」「あのー」）を消して、整った文章に変換するボイスアプリ。

ブラウザだけで動く。インストール不要・アカウント不要。

## 何ができるか

- 🎙️ マイクで話す → 自動で文字起こし → AIが整形（フィラー除去・繰り返し削除・言い直しの自動編集）
- ✦ 4つのスタイル：そのまま整える / メール / チャット / 箇条書き
- 📁 音声ファイル（mp3 / m4a / wav）のドラッグ&ドロップにも対応
- 📋 ワンタップでコピー、履歴はブラウザ（localStorage）にだけ保存

## 構成（オニオン型）

```
src/
  core/cleanup.js   業務ルール（フィラー除去・プロンプト）。純粋関数だけ
  adapters/ai.js    外部接続（Claude API / Workers AI Whisper・LLM）
  index.js          入口。APIの封筒は { ok:true/false } で統一
public/
  index.html        ランディングページ
  app.html          アプリ本体
```

- **文字起こし**：Workers AI の Whisper（鍵不要・無料枠）
- **整形**：Claude Haiku（`ANTHROPIC_API_KEY`）→ 無ければ Workers AI → 無ければルールベース、の3段フォールバック

## 開発・デプロイ

```bash
# ローカルで動かす
npx wrangler dev

# デプロイ
npx wrangler deploy

# AI整形の質を上げる（任意・推奨）
npx wrangler secret put ANTHROPIC_API_KEY

# 公開URLを合言葉で守る（任意）
npx wrangler secret put APP_PASSWORD
```

## プライバシー

- 音声は文字起こしのためだけに処理し、サーバーには保存しない
- 履歴は端末のブラウザにだけ保存
- 音声データをモデルの学習に使わない
