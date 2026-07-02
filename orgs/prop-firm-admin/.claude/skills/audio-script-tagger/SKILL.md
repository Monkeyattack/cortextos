---
name: audio-script-tagger
description: "Inject OmniVoice in-text tags and non-speech pacing markers into a raw script before TTS synthesis, applying channel-specific register rules (chrismeredith / ai-theist / phantom-findings). Use before any OmniVoice RunPod synthesis job — never send an untagged script to audio rendering. The tagged output IS the synthesis input."
triggers: ["tag script for omnivoice", "audio script tags", "prep script for tts", "tag this for synthesis", "add omnivoice tags", "tag the narration"]
---

# audio-script-tagger

Inject OmniVoice in-text tags and non-speech markers into a raw script to make audio rendering more naturalistic and impactful. Use before any OmniVoice synthesis job.

## When to Use

Invoke before passing any script to the OmniVoice RunPod endpoint. The tagged output is the synthesis input — never send untagged scripts to audio rendering.

## Input

- `script`: raw text (paragraphs, no existing tags)
- `channel_id`: one of `chrismeredith`, `ai-theist`, `phantom-findings`

## OmniVoice Tag Reference

All tags insert BEFORE the word/phrase they modify.

| Tag | Effect |
|-----|--------|
| `[confirmation-en]` | Affirming "mm-hmm" / "right" |
| `[question-en]` | Rising intonation on next syllable |
| `[question-ah]` | Soft questioning "ah?" |
| `[question-oh]` | Questioning "oh?" |
| `[sigh]` | Soft exhale — weight, resignation |
| `[laughter]` | Audible laughter (use sparingly) |
| `[surprise-ah]` | Sharp "ah!" — genuine anomaly |
| `[surprise-oh]` | Restrained "oh!" surprise |
| `[surprise-wa]` | Dramatic "wa!" |
| `[dissatisfaction-hnn]` | Skeptical "hmm" |

Non-speech pacing markers (not OmniVoice tags — handled by script formatting):
- `(PAUSE)` — deliberate 0.5–1s silence before impact line
- `—` em-dash — trailing thought with slight pause
- `...` — trailing off before redirect

## Per-Channel Rules

### chrismeredith (analytical NLP peer, speed=0.95)

**Register**: authoritative, peer-to-peer, data-driven. Never informal.

- `[question-en]` — every rhetorical question where answer follows immediately
  - Example: `Who captured that? [question-en] The early employees.`
- `[confirmation-en]` — after landing a key data point
  - Example: `That is a 133x return. [confirmation-en]`
- `[sigh]` — once per major section reveal, before uncomfortable truth
  - Example: `SpaceX has no mechanism to remove its CEO. [sigh] The only vote requires his own participation.`
- `[surprise-ah]` — only for genuinely anomalous data
- **AVOID**: `[laughter]`, `[dissatisfaction-hnn]`, `[surprise-wa]`, `[surprise-yo]`
- **Frequency**: 1–2 tags per 100 words. Never consecutive.

### ai-theist (conspiratorial elder, speed=0.88)

**Register**: gravelly, skeptical, building dread. More emotive.

- `[question-en]` — every hook line
  - Example: `Does the Vatican know? [question-en]`
- `[dissatisfaction-hnn]` — after dismissing official narrative
- `[sigh]` — before revealing "the real truth"
- `[surprise-ah]` — genuine revelation moments
- `[laughter]` — dark irony only, maximum once per script
- **Frequency**: 2–3 tags per 100 words

### phantom-findings (Attenborough academic lecturer, speed=0.92)

**Register**: documentary gravity, restrained. Most sparing of the three.

- `[question-en]` — after planting the mystery question
  - Example: `What did the rangers find? [question-en]`
- `[sigh]` — before solemn facts, deaths, disappearances
- `[confirmation-en]` — when presenting hard evidence
- `[surprise-oh]` — restrained surprise at evidence
- **AVOID**: `[laughter]`, `[surprise-wa]`, `[surprise-yo]`
- **Frequency**: 1 tag per 120 words — most restrained

## Execution Steps

1. Read the full script. Identify the channel_id and load its rules above.

2. Pass the script to a subagent with this prompt:
```
You are tagging a script for OmniVoice text-to-speech synthesis.

Channel: <channel_id>
Voice persona: <one-line persona description>

Rules:
<paste the channel's rules from above>

Script:
<raw script>

Instructions:
- Insert OmniVoice tags (e.g. [question-en]) BEFORE the word/phrase they modify
- Add (PAUSE) before any line that needs deliberate silence for impact
- Use em-dash (—) for natural trailing pauses
- Respect the frequency limits exactly — count tags per 100 words
- Never place two tags consecutively
- Do not change any wording — only add tags and pacing markers
- Return ONLY the tagged script, no commentary
```

3. Validate the output:
   - Count tags per 100 words — flag if over limit
   - Confirm no consecutive tags
   - Confirm no wording changes

4. Return tagged script. This is the direct input for the OmniVoice endpoint call.

## Notes

- Speed is set at the endpoint level via `channel_id` lookup — do not embed speed in the script
- The `chrismeredith` channel uses voice cloning (reference audio baked into endpoint); others use instruct-based design
- ttsProvider cutover from ElevenLabs → OmniVoice happens when the RunPod endpoint URL is confirmed (media agent owns that DB update)
