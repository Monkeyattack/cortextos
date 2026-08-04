#!/usr/bin/env bash
# MiniMax API test harness — image / speech / music
# Usage: ./harness.sh [image|speech|music|concurrency|all]
set -uo pipefail

OUT=/tmp/minimax-test
BASE=https://api.minimax.io/v1
mkdir -p "$OUT"

export VAULT_SKIP_VERIFY=true
MMK="${MINIMAX_API_KEY:-$(vault kv get -field=api_key secret/minimax 2>/dev/null)}"
[[ -z "$MMK" ]] && { echo "FATAL: no api key"; exit 1; }

AUTH=(-H "Authorization: Bearer $MMK" -H "Content-Type: application/json")
LOG="$OUT/results.jsonl"

# call <name> <path> <json-body>  -> writes $OUT/<name>.json, logs timing
call() {
  local name="$1" path="$2" body="$3"
  local t0 t1
  t0=$(date +%s.%N)
  curl -s -X POST "$BASE/$path" "${AUTH[@]}" -d "$body" -o "$OUT/$name.json" -w '%{http_code}' > "$OUT/$name.code"
  t1=$(date +%s.%N)
  local secs; secs=$(python3 -c "print(f'{$t1-$t0:.2f}')")
  local code; code=$(cat "$OUT/$name.code")
  # TRAP: MiniMax returns HTTP 200 even for rate-limit/auth errors. base_resp.status_code
  # is the ONLY reliable success signal (0 = ok, 1002 = RPM exceeded, 2049 = bad key).
  local status; status=$(python3 -c "
import json,sys
d=json.load(open('$OUT/$name.json')).get('base_resp',{})
sc=d.get('status_code')
print(('OK' if sc==0 else f'ERR[{sc}] ')+d.get('status_msg','?'))" 2>/dev/null || echo parse_error)
  printf '{"test":"%s","http":%s,"secs":%.2f,"status":"%s"}\n' "$name" "$code" "$secs" "$status" | tee -a "$LOG"
}

fetch_urls() { # <name> <prefix>
  python3 - "$OUT/$1.json" "$OUT/$2" <<'PY'
import json,sys,urllib.request
d=json.load(open(sys.argv[1]))
for i,u in enumerate(d.get("data",{}).get("image_urls",[])):
    p=f"{sys.argv[2]}_{i}.jpg"
    urllib.request.urlretrieve(u,p); print("saved",p)
PY
}

hex_to_file() { # <name> <jsonpath-key> <outfile>
  python3 - "$OUT/$1.json" "$2" "$OUT/$3" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
h=d.get("data",{}).get(sys.argv[2]) or d.get(sys.argv[2])
if not h: print("NO AUDIO:", json.dumps(d)[:400]); sys.exit(1)
open(sys.argv[3],"wb").write(bytes.fromhex(h)); print("saved",sys.argv[3],len(h)//2,"bytes")
PY
}

run_image() {
  echo "=== IMAGE ==="
  call img1 image_generation '{"model":"image-01","prompt":"Cinematic wide shot of a lone trader silhouetted against a wall of glowing market charts in a dark office, volumetric light, photorealistic, 35mm film grain","aspect_ratio":"16:9","response_format":"url","n":1,"prompt_optimizer":true}'
  fetch_urls img1 img1_trader
  call img2 image_generation '{"model":"image-01","prompt":"Flat vector logo mark for an AI ops company: abstract hexagonal node network, two-color teal and charcoal, clean negative space, centered on white background","aspect_ratio":"1:1","response_format":"url","n":1,"prompt_optimizer":true}'
  fetch_urls img2 img2_logo
  call img3 image_generation '{"model":"image-01","prompt":"YouTube thumbnail: shocked man in a blue shirt pointing at a giant red downward stock arrow, bold high-contrast lighting, lots of empty space on the right for text","aspect_ratio":"16:9","response_format":"url","n":1,"prompt_optimizer":true}'
  fetch_urls img3 img3_thumb
}

run_speech() {
  echo "=== SPEECH ==="
  call tts1 t2a_v2 '{"model":"speech-02-hd","text":"MiniMax test harness. This is a short evaluation phrase for the creative studio fleet, recorded at forty-four point one kilohertz.","stream":false,"voice_setting":{"voice_id":"English_expressive_narrator","speed":1.0,"vol":1.0,"pitch":0},"audio_setting":{"sample_rate":32000,"bitrate":128000,"format":"mp3","channel":1}}'
  hex_to_file tts1 audio tts1.mp3
}

run_music() {
  echo "=== MUSIC ==="
  call music1 music_generation '{"model":"music-1.5","prompt":"Uplifting corporate lo-fi hip hop, warm rhodes keys, soft vinyl crackle, 85 bpm, optimistic","lyrics":"##\nWe build it in the quiet hours\nLines of light across the wire\nEvery signal finds its power\nEvery ember finds its fire\n##","audio_setting":{"sample_rate":44100,"bitrate":256000,"format":"mp3"},"output_format":"hex"}'
  hex_to_file music1 audio music1.mp3
}

run_concurrency() {
  echo "=== CONCURRENCY (6 parallel image calls = fleet size) ==="
  local pids=()
  for i in $(seq 1 6); do
    ( curl -s -X POST "$BASE/image_generation" "${AUTH[@]}" \
        -d "{\"model\":\"image-01\",\"prompt\":\"abstract geometric pattern number $i, minimal, monochrome\",\"aspect_ratio\":\"1:1\",\"response_format\":\"url\",\"n\":1}" \
        -o "$OUT/conc_$i.json" -w "conc_$i http=%{http_code} t=%{time_total}s\n" ) &
    pids+=($!)
  done
  for p in "${pids[@]}"; do wait "$p"; done
  for i in $(seq 1 6); do
    python3 -c "import json;d=json.load(open('$OUT/conc_$i.json'));print('conc_$i ->',d.get('base_resp'))" 2>/dev/null
  done
}

case "${1:-all}" in
  image) run_image ;;
  speech) run_speech ;;
  music) run_music ;;
  concurrency) run_concurrency ;;
  all) run_image; run_speech; run_music; run_concurrency ;;
esac
echo "--- results in $OUT ---"
ls -la "$OUT"
