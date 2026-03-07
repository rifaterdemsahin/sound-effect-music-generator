#!/usr/bin/env bash
# soundfx.sh — Sound Effect Generator CLI (macOS / Linux / Stream Deck)
# Usage:
#   ./soundfx.sh script.txt              # Analyse script, print prompts
#   ./soundfx.sh script.txt --generate   # Analyse + generate sound effects
#   ./soundfx.sh --test                  # Test API connections

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

# ─── Load .env ────────────────────────────────────────────────────────────────
if [[ -f "$ENV_FILE" ]]; then
  # Export only KEY=value lines (ignore comments and blank lines)
  set -a
  # shellcheck disable=SC1090
  source <(grep -E '^[A-Z_]+=.*' "$ENV_FILE" | sed 's/#.*//')
  set +a
else
  echo "⚠️  No .env file found at $ENV_FILE"
  echo "   Copy .env.example to .env and fill in your API keys."
fi

ELEVENLABS_API_KEY="${ELEVENLABS_API_KEY:-}"
FAL_API_KEY="${FAL_API_KEY:-}"
XAI_API_KEY="${XAI_API_KEY:-}"
BACKEND="${BACKEND:-elevenlabs}"
VARIANTS="${VARIANTS:-3}"

OUTPUT_DIR="${SCRIPT_DIR}/generated_sounds"
mkdir -p "$OUTPUT_DIR"

# ─── Helpers ──────────────────────────────────────────────────────────────────
check_deps() {
  local missing=()
  for cmd in curl jq; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "❌ Missing required tools: ${missing[*]}"
    echo "   Install with: brew install ${missing[*]}  (macOS)"
    exit 1
  fi
}

print_usage() {
  cat <<EOF
Usage:
  $(basename "$0") <script_file> [--generate] [--variants N] [--backend elevenlabs|fal]
  $(basename "$0") --test

Options:
  --generate        Generate audio files for each suggested prompt
  --variants N      Number of audio variants to generate per prompt (default: $VARIANTS)
  --backend NAME    Override generation backend: elevenlabs or fal (default: $BACKEND)
  --test            Test API connections and exit

Environment (.env):
  ELEVENLABS_API_KEY   ElevenLabs API key
  FAL_API_KEY          fal.ai API key
  XAI_API_KEY          Grok/xAI API key
  BACKEND              elevenlabs or fal
  VARIANTS             Number of variants per prompt
EOF
}

# ─── Connection Tests ─────────────────────────────────────────────────────────
test_elevenlabs() {
  local key="$1"
  if [[ -z "$key" ]]; then echo "❌ ElevenLabs: No API key set"; return 1; fi
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "xi-api-key: $key" \
    "https://api.elevenlabs.io/v1/user")
  if [[ "$http_code" == "200" ]]; then
    echo "✅ ElevenLabs: Connected (HTTP $http_code)"
    return 0
  else
    echo "❌ ElevenLabs: Failed (HTTP $http_code)"
    return 1
  fi
}

test_fal() {
  local key="$1"
  if [[ -z "$key" ]]; then echo "❌ fal.ai: No API key set"; return 1; fi
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "Authorization: Key $key" \
    -H "Content-Type: application/json" \
    -d '{"prompt":"test","seconds_total":1}' \
    "https://fal.run/fal-ai/stable-audio")
  # 401/403 = auth fail; 4xx other = auth ok but bad request
  if [[ "$http_code" == "401" || "$http_code" == "403" ]]; then
    echo "❌ fal.ai: Auth failed (HTTP $http_code)"
    return 1
  else
    echo "✅ fal.ai: Connected (HTTP $http_code)"
    return 0
  fi
}

test_xai() {
  local key="$1"
  if [[ -z "$key" ]]; then echo "❌ Grok/xAI: No API key set"; return 1; fi
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer $key" \
    "https://api.x.ai/v1/models")
  if [[ "$http_code" == "200" ]]; then
    echo "✅ Grok/xAI: Connected (HTTP $http_code)"
    return 0
  else
    echo "❌ Grok/xAI: Failed (HTTP $http_code)"
    return 1
  fi
}

run_connection_tests() {
  echo "🔌 Testing API connections…"
  echo ""
  test_elevenlabs "$ELEVENLABS_API_KEY" || true
  test_fal        "$FAL_API_KEY"        || true
  test_xai        "$XAI_API_KEY"        || true
  echo ""
}

# ─── Grok Analysis ────────────────────────────────────────────────────────────
analyse_script() {
  local script_content="$1"
  if [[ -z "$XAI_API_KEY" ]]; then
    echo "❌ XAI_API_KEY is not set. Cannot analyse script."
    exit 1
  fi

  echo "🔍 Analysing script with Grok…"

  local payload
  payload=$(jq -n \
    --arg content "$script_content" \
    '{
      model: "grok-beta",
      temperature: 0.3,
      messages: [
        {
          role: "system",
          content: "You are a professional sound designer for video production. Analyse the provided video script and return a JSON array of sound effect suggestions. Each suggestion must be an object with: \"timestamp\" (string, e.g. \"0:05\"), \"prompt\" (concise text-to-audio description), \"reason\" (why this sound fits). Return ONLY valid JSON, no markdown, no extra text."
        },
        {
          role: "user",
          content: ("Analyse this video script and suggest sound effects:\n\n" + $content)
        }
      ]
    }')

  local response
  response=$(curl -s -X POST \
    -H "Authorization: Bearer $XAI_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "https://api.x.ai/v1/chat/completions")

  local suggestions
  suggestions=$(echo "$response" | jq -r '.choices[0].message.content' 2>/dev/null || echo "")

  if [[ -z "$suggestions" || "$suggestions" == "null" ]]; then
    echo "❌ Failed to get suggestions from Grok."
    echo "Response: $response"
    exit 1
  fi

  echo "$suggestions"
}

# ─── Sound Generation ─────────────────────────────────────────────────────────
generate_elevenlabs() {
  local prompt="$1"
  local outfile="$2"
  local payload
  payload=$(jq -n --arg text "$prompt" '{text: $text, duration_seconds: null, prompt_influence: 0.3}')

  local http_code
  http_code=$(curl -s -o "$outfile" -w "%{http_code}" \
    -X POST \
    -H "xi-api-key: $ELEVENLABS_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "https://api.elevenlabs.io/v1/sound-generation")

  if [[ "$http_code" == "200" ]]; then
    echo "  ✅ Saved: $outfile"
  else
    echo "  ❌ ElevenLabs error (HTTP $http_code) for: $prompt"
    rm -f "$outfile"
  fi
}

generate_fal() {
  local prompt="$1"
  local outfile="$2"
  local payload
  payload=$(jq -n --arg prompt "$prompt" '{prompt: $prompt, seconds_total: 10, steps: 100}')

  local response
  response=$(curl -s -X POST \
    -H "Authorization: Key $FAL_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "https://fal.run/fal-ai/stable-audio")

  local audio_url
  audio_url=$(echo "$response" | jq -r '.audio_file.url // .audio.url // .outputs[0].url // empty' 2>/dev/null)

  if [[ -z "$audio_url" ]]; then
    echo "  ❌ fal.ai: No audio URL returned for: $prompt"
    return 1
  fi

  curl -s -L -o "$outfile" "$audio_url"
  echo "  ✅ Saved: $outfile"
}

# ─── Main ─────────────────────────────────────────────────────────────────────
check_deps

SCRIPT_FILE=""
DO_GENERATE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --test)
      run_connection_tests
      exit 0
      ;;
    --generate)
      DO_GENERATE=true
      shift
      ;;
    --variants)
      VARIANTS="$2"
      shift 2
      ;;
    --backend)
      BACKEND="$2"
      shift 2
      ;;
    --help|-h)
      print_usage
      exit 0
      ;;
    -*)
      echo "Unknown option: $1"
      print_usage
      exit 1
      ;;
    *)
      SCRIPT_FILE="$1"
      shift
      ;;
  esac
done

if [[ -z "$SCRIPT_FILE" ]]; then
  print_usage
  exit 1
fi

if [[ ! -f "$SCRIPT_FILE" ]]; then
  echo "❌ Script file not found: $SCRIPT_FILE"
  exit 1
fi

SCRIPT_CONTENT=$(cat "$SCRIPT_FILE")

# Analyse
SUGGESTIONS_JSON=$(analyse_script "$SCRIPT_CONTENT")

echo ""
echo "📋 Suggested Sound Effects:"
echo "─────────────────────────────────────────"

# Validate JSON
if ! echo "$SUGGESTIONS_JSON" | jq '.' &>/dev/null; then
  # Try extracting JSON array if model added extra text
  SUGGESTIONS_JSON=$(echo "$SUGGESTIONS_JSON" | grep -o '\[.*\]' | head -1 || echo "[]")
fi

echo "$SUGGESTIONS_JSON" | jq -r '.[] | "[\(.timestamp)] \(.prompt)  — \(.reason)"'

PROMPT_COUNT=$(echo "$SUGGESTIONS_JSON" | jq 'length')
echo "─────────────────────────────────────────"
echo "Total: $PROMPT_COUNT prompts"

if [[ "$DO_GENERATE" == true ]]; then
  echo ""
  echo "🎵 Generating sound effects (backend: $BACKEND, variants: $VARIANTS)…"
  echo ""

  TIMESTAMP=$(date +%Y%m%d_%H%M%S)

  while IFS= read -r suggestion; do
    PROMPT=$(echo "$suggestion" | jq -r '.prompt')
    TS=$(echo "$suggestion" | jq -r '.timestamp')
    SAFE_PROMPT=$(echo "$PROMPT" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g' | cut -c1-40)

    echo "🔊 [$TS] $PROMPT"

    for ((v=1; v<=VARIANTS; v++)); do
      OUTFILE="${OUTPUT_DIR}/${TIMESTAMP}_${SAFE_PROMPT}_v${v}.mp3"
      if [[ "$BACKEND" == "fal" ]]; then
        generate_fal "$PROMPT" "$OUTFILE"
      else
        generate_elevenlabs "$PROMPT" "$OUTFILE"
      fi
    done
    echo ""
  done < <(echo "$SUGGESTIONS_JSON" | jq -c '.[]')

  echo "✅ Done! Files saved to: $OUTPUT_DIR"
fi
