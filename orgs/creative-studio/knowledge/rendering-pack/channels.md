# Channel Schema

Source of truth: `aitheist` PostgreSQL DB (127.0.0.1:5432) + Postiz DB (postiz-postgres container).

---

## AI Theist DB — channels table

| channel_id | name | heygen_avatar_id | elevenlabs_voice_id | brand_color | target_platforms |
|-----------|------|-----------------|-------------------|-------------|-----------------|
| ai-theist | AI Theist | Abigail_expressive_2024112501 | (none) | #888888 | youtube |
| chris-meredith | Chris Meredith | (none) | kyj06yo9f25k | #1a1a2e | youtube |
| phantom-findings | Phantom Findings | (none) | (none) | #3d1a5c | youtube, tiktok |
| wendy-recap | WendyRECAP | Abigail_expressive_2024112501 | (none) | #FF6B6B | youtube |

**Schema columns (jobs table):** id (uuid), source_url, source_platform, extracted_text, script (jsonb), status, input_type (url/text/script), channel_id, thumbnails (jsonb), series_metadata (jsonb)

**job_status enum:** ingested, classified, scripted, rendered, published, error

---

## Postiz DB — Integration IDs

| channel_id | name | Postiz integration_id | type |
|-----------|------|----------------------|------|
| ai-theist | AI-Theist-IO | cms82dw7m000tpmd7zf4irf6a | youtube |
| ai-theist | AI-Theist-IO | cms82efmu000vpmd7gelf8u3g | youtube |
| ai-theist | AI-Theist-IO | cmqh3g7x40005pmekeprp9x87 | youtube |
| chris-meredith | Christopher Meredith | cms82da4n000rpmd77v1671b7 | youtube |
| chris-meredith | Christopher Meredith | cmqh3dahs0001pmekt2wx31tu | youtube |
| chris-meredith | Christopher Meredith | cms855no70001ntcbvg3ig0my | linkedin |
| phantom-findings | Phantom Findings | cmqh3f3dn0003pmekl0fwf5d8 | youtube |

**Postiz CLI:** set `POSTIZ_API_URL=https://postiz.profithits.app/api` before any `postiz` command. Self-hosted instance (not SaaS).

---

## Canonical Outro Voice

- **chris-meredith:** ElevenLabs voice `kyj06yo9f25k`
- **ai-theist / wendy-recap:** HeyGen avatar `Abigail_expressive_2024112501`
- **phantom-findings:** no canonical voice/avatar (visual-only)
