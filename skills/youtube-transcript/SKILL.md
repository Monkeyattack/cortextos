---
name: youtube-transcript
description: |
  Get a YouTube video transcript using Supadata MCP. Fast, no download, works from VPS (bypasses IP block).
  Use when: (1) Chris shares a YouTube URL and wants it read/summarized, (2) Any agent needs transcript content from a YouTube video. Primary path — prefer over yt-dlp on VPS environments.
---

# youtube-transcript

Pull YouTube transcripts via Supadata MCP. No video download, no IP-block issues.

**Note:** yt-dlp is blocked on this VPS for YouTube (cloud IP). Supadata is the reliable path. [[feedback_youtube_blocks_vps]]

## Prerequisites

Supadata MCP must be authenticated. Chris authed it 2026-06-30 — it's active for braindump/notes and any agent with the MCP wired.

To check auth status: call `mcp__supadata__*` — if it returns a login prompt, run the auth flow below.

### One-time auth (if needed)
```
1. Call mcp__supadata__authenticate
2. Send Chris the auth URL
3. Chris approves and pastes back the callback URL (localhost/callback?code=...)
4. Call mcp__supadata__complete_authentication with that URL
5. Auth persists — no need to repeat
```

## Get a transcript

```
Tool: mcp__supadata__*
Action: fetch YouTube transcript
Input: YouTube URL or video ID
```

The tool returns the full transcript text with timestamps. Extract the text content and use it directly.

## Routing by content type

| Source | Tool | Notes |
|--------|------|-------|
| YouTube URL | `mcp__supadata__*` | Primary — fast, no download |
| TikTok / Instagram | `yt-dlp --write-subs --skip-download` | Supadata covers YouTube only |
| Local video file | `video-understand` skill | ffmpeg + Whisper, fully offline |
| Already have .mp4 | `video-understand` skill | Same |

## After getting the transcript

- Summarize / evaluate per the user's ask
- If capturing for research: `cortextos bus kb-ingest` the summary
- If sharing with Chris: mint a URL via `mint-preview-url.sh` and send the link — don't paste the full transcript inline [[feedback_telegram_brief_pointer_pattern]]

## Fallback if Supadata fails

```bash
# Download captions only (no video) — works for non-YouTube or if supadata is down
yt-dlp "URL" --write-subs --sub-langs en --skip-download --output "%(title)s.%(ext)s"
# Then read the .vtt/.srt file
```
