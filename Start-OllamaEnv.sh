#!/usr/bin/env bash
# =============================================================================
#  Start-OllamaEnv.sh
#  Automates a local AI coding environment using Ollama + VS Code.
#
#  Steps:
#    1. Ensure the Ollama server is running (starts it in the background).
#    2. List locally-pulled models and let you pick one interactively.
#    3. Check VRAM — warn about memory pressure, offer a quantization menu
#       when the chosen model does not fit, and pull the smaller variant.
#    4. Export OLLAMA_HOST / OLLAMA_MODEL and write .vscode/settings.json
#       so VS Code extensions find the server automatically.
#    5. Open VS Code in the target directory with usage instructions.
#
#  Usage:
#    bash Start-OllamaEnv.sh [WORK_DIR] [OLLAMA_HOST]
#
#  Defaults:
#    WORK_DIR     = current directory ($PWD)
#    OLLAMA_HOST  = 127.0.0.1:11434
#
#  Requirements:
#    - ollama CLI on PATH       (https://ollama.com/download)
#    - nvidia-smi on PATH       (NVIDIA GPU, optional but recommended)
#    - rocm-smi  on PATH        (AMD GPU,    optional)
#    - code CLI  on PATH        (VS Code → Help → Shell Command → Install 'code')
#    - jq        on PATH        (optional, for robust JSON parsing)
# =============================================================================

set -euo pipefail

WORK_DIR="${1:-$PWD}"
OLLAMA_HOST="${2:-127.0.0.1:11434}"

# ─────────────────────────────────────────────────────────────────────────────
# HELPERS
# ─────────────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; WHITE='\033[1;37m'; GRAY='\033[0;37m'
DYELLOW='\033[0;33m'; NC='\033[0m'  # No Color

header()  { echo -e "\n${CYAN}━━━  $*  ━━━${NC}"; }
ok()      { echo -e "  ${GREEN}[OK]${NC}  $*"; }
warn()    { echo -e "  ${YELLOW}[!!]${NC}  $*"; }
info()    { echo -e "  ${WHITE}[··]${NC}  $*"; }
fail()    { echo -e "  ${RED}[XX]${NC}  $*"; }

# Convert "4.7 GB" / "2048 MB" → integer MiB
to_mib() {
    local s="$1"
    if [[ "$s" =~ ([0-9]+\.?[0-9]*)[[:space:]]*(GB|GiB) ]]; then
        echo $(python3 -c "print(round(${BASH_REMATCH[1]} * 1024))" 2>/dev/null || \
               awk "BEGIN{printf \"%d\", ${BASH_REMATCH[1]} * 1024}")
    elif [[ "$s" =~ ([0-9]+\.?[0-9]*)[[:space:]]*(MB|MiB) ]]; then
        echo $(python3 -c "print(round(${BASH_REMATCH[1]}))" 2>/dev/null || \
               awk "BEGIN{printf \"%d\", ${BASH_REMATCH[1]}}")
    else
        echo ""
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1 — Ensure Ollama server is running
# ─────────────────────────────────────────────────────────────────────────────
header "STEP 1 of 5 — Ollama Server"

if ! command -v ollama &>/dev/null; then
    fail "ollama not found on PATH."
    info "Install from https://ollama.com/download, then re-run."
    exit 1
fi

if pgrep -x "ollama" &>/dev/null; then
    ok "Ollama process already running (PID $(pgrep -x ollama | head -1))."
else
    info "Starting ollama serve in the background..."
    nohup ollama serve &>/dev/null &
    disown

    # Wait up to 10 s for the API
    API_URL="http://${OLLAMA_HOST}"
    READY=false
    for i in $(seq 1 10); do
        sleep 1
        if curl -sf --max-time 2 "$API_URL" &>/dev/null; then
            READY=true; break
        fi
    done
    if $READY; then ok "Server started and reachable at $API_URL."
    else warn "Server started but did not respond within 10 s. Continuing."; fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1b — Pull missing models from models.txt (if the file exists)
# ─────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELS_FILE="${SCRIPT_DIR}/models.txt"

if [[ -f "$MODELS_FILE" ]]; then
    header "STEP 1b — Pull Missing Models from models.txt"
    info "Reading model list: $MODELS_FILE"

    # Get already-installed model names into a lookup string
    INSTALLED=$(ollama list 2>/dev/null | tail -n +2 | awk '{print $1}')

    while IFS= read -r LINE || [[ -n "$LINE" ]]; do
        # Strip comments and blank lines
        LINE="${LINE%%#*}"              # remove inline comments
        LINE="${LINE//[$'\t' ]}"       # strip all whitespace
        [[ -z "$LINE" ]] && continue

        # Check if already pulled (match name ignoring tag differences)
        BASE_CHECK="${LINE%%:*}"
        ALREADY_PULLED=false
        while IFS= read -r INST; do
            if [[ "$INST" == "$LINE" ]] || [[ "$INST" == "${BASE_CHECK}:latest" ]]; then
                ALREADY_PULLED=true
                break
            fi
        done <<< "$INSTALLED"

        if $ALREADY_PULLED; then
            ok "Already installed: $LINE"
        else
            info "Pulling $LINE ..."
            if ollama pull "$LINE"; then
                ok "Pulled: $LINE"
            else
                warn "Failed to pull $LINE (exit $?). Skipping."
            fi
        fi
    done < "$MODELS_FILE"
else
    info "No models.txt found at $MODELS_FILE — skipping auto-pull."
    info "Create OlamaCLI/models.txt (one model per line) to enable auto-pull."
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2 — List pulled models and let the user select one
# ─────────────────────────────────────────────────────────────────────────────
header "STEP 2 of 5 — Model Selection"

# Build arrays: MODEL_NAMES[], MODEL_SIZES[]
MODEL_NAMES=()
MODEL_SIZES=()

if command -v jq &>/dev/null; then
    # Prefer JSON output when jq is available
    while IFS= read -r line; do
        MODEL_NAMES+=("$line")
    done < <(ollama list --format json 2>/dev/null | jq -r '.models[].name' 2>/dev/null || true)
    while IFS= read -r line; do
        MODEL_SIZES+=("$line")
    done < <(ollama list --format json 2>/dev/null | jq -r '.models[].size' 2>/dev/null || true)
fi

# Fallback: parse plain text
if [[ ${#MODEL_NAMES[@]} -eq 0 ]]; then
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        NAME=$(echo "$line" | awk '{print $1}')
        SIZE=$(echo "$line" | awk '{print $NF}')
        MODEL_NAMES+=("$NAME")
        MODEL_SIZES+=("$SIZE")
    done < <(ollama list 2>/dev/null | tail -n +2)
fi

SELECTED_MODEL=""
if [[ ${#MODEL_NAMES[@]} -eq 0 ]]; then
    warn "No models found locally."
    info "Pull one first:  ollama pull llama3   |  ollama pull codellama"
else
    info "Locally available models:"
    for i in "${!MODEL_NAMES[@]}"; do
        printf "    [%2d]  %-42s %s\n" "$((i+1))" "${MODEL_NAMES[$i]}" "${MODEL_SIZES[$i]:-?}"
    done
    echo ""
    while true; do
        read -rp "  Enter model number to activate (or press Enter to skip): " CHOICE
        [[ -z "$CHOICE" ]] && break
        if [[ "$CHOICE" =~ ^[0-9]+$ ]] && \
           [[ "$CHOICE" -ge 1 ]] && [[ "$CHOICE" -le ${#MODEL_NAMES[@]} ]]; then
            SELECTED_MODEL="${MODEL_NAMES[$((CHOICE-1))]}"
            ok "Selected model: $SELECTED_MODEL"
            break
        fi
        warn "Invalid choice — enter a number between 1 and ${#MODEL_NAMES[@]}."
    done
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3 — VRAM check + interactive quantization menu
# ─────────────────────────────────────────────────────────────────────────────
header "STEP 3 of 5 — VRAM / Memory Check"

TOTAL_VRAM_MIB=""; USED_VRAM_MIB=""; GPU_NAME="Unknown GPU"
APPLE_SILICON=false

# ── Apple Silicon (M1/M2/M3/M4/M5 — unified memory) ─────────────────────────
# Ollama uses Metal on macOS and can access the full unified memory pool.
# There is no separate VRAM; we report total RAM and estimate used memory
# from the Ollama API (which models are currently loaded).
if [[ "$(uname -s)" == "Darwin" ]] && [[ "$(uname -m)" == "arm64" ]]; then
    APPLE_SILICON=true
    GPU_NAME=$(system_profiler SPDisplaysDataType 2>/dev/null \
               | awk -F': ' '/Chipset Model/{print $2; exit}' || echo "Apple Silicon GPU")
    TOTAL_RAM_BYTES=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
    TOTAL_VRAM_MIB=$(awk "BEGIN{printf \"%d\", $TOTAL_RAM_BYTES / 1048576}")
    # Estimate available memory for Ollama: total minus a fixed 4 GiB OS/system reserve
    OS_RESERVE_MIB=4096
    # Query Ollama API for models currently loaded in memory
    LOADED_MIB=0
    LOADED_JSON=$(curl -sf --max-time 3 "http://${OLLAMA_HOST}/api/ps" 2>/dev/null || echo "{}")
    if command -v python3 &>/dev/null; then
        LOADED_MIB=$(python3 - <<PYEOF
import json, sys
try:
    data = json.loads('''$LOADED_JSON''')
    total = sum(m.get("size_vram", m.get("size", 0)) for m in data.get("models", []))
    print(int(total / 1048576))
except Exception:
    print(0)
PYEOF
        )
    fi
    USED_VRAM_MIB=$(( OS_RESERVE_MIB + LOADED_MIB ))
    # Cap at total (can happen if estimate is off)
    [[ "$USED_VRAM_MIB" -gt "$TOTAL_VRAM_MIB" ]] && USED_VRAM_MIB=$TOTAL_VRAM_MIB
    info "Apple Silicon detected — unified memory is shared between CPU and GPU."
    info "Ollama uses the Metal backend and can access the full memory pool."
fi

# ── NVIDIA ────────────────────────────────────────────────────────────────────
if [[ -z "$TOTAL_VRAM_MIB" ]] && command -v nvidia-smi &>/dev/null; then
    NVOUT=$(nvidia-smi --query-gpu=name,memory.total,memory.used \
                       --format=csv,noheader,nounits 2>/dev/null | head -1 || true)
    if [[ -n "$NVOUT" ]]; then
        GPU_NAME=$(echo "$NVOUT" | cut -d',' -f1 | xargs)
        TOTAL_VRAM_MIB=$(echo "$NVOUT" | cut -d',' -f2 | xargs)
        USED_VRAM_MIB=$(echo "$NVOUT"  | cut -d',' -f3 | xargs)
    fi
fi

# ── AMD fallback ──────────────────────────────────────────────────────────────
if [[ -z "$TOTAL_VRAM_MIB" ]] && command -v rocm-smi &>/dev/null; then
    ROCMOUT=$(rocm-smi --showmeminfo vram --csv 2>/dev/null | tail -n +2 | head -1 || true)
    if [[ -n "$ROCMOUT" ]]; then
        GPU_NAME="AMD GPU"
        TOTAL_VRAM_MIB=$(echo "$ROCMOUT" | cut -d',' -f2 | awk '{printf "%d", $1/1048576}')
        USED_VRAM_MIB=$(echo "$ROCMOUT"  | cut -d',' -f3 | awk '{printf "%d", $1/1048576}')
    fi
fi

# ── Interactive quantization menu ────────────────────────────────────────────
QUANT_TAGS=("q8_0"   "q6_K"   "q5_K_M" "q4_K_M" "q3_K_M" "q2_K")
QUANT_LABELS=(
    "Q8_0   — 8-bit,  ~100 % quality, ~12 % smaller  (best for large VRAM)"
    "Q6_K   — 6-bit,  ~99 % quality,  ~35 % smaller"
    "Q5_K_M — 5-bit,  ~97 % quality,  ~41 % smaller  (recommended)"
    "Q4_K_M — 4-bit,  ~95 % quality,  ~50 % smaller  (most popular)"
    "Q3_K_M — 3-bit,  ~91 % quality,  ~62 % smaller"
    "Q2_K   — 2-bit,  ~85 % quality,  ~75 % smaller  (last resort)"
)

invoke_quant_menu() {
    local BASE="$1"
    echo ""
    warn "Quantization options for '${BASE}':"
    for i in "${!QUANT_TAGS[@]}"; do
        echo -e "    ${DYELLOW}[$((i+1))]  ${QUANT_LABELS[$i]}${NC}"
    done
    echo -e "    ${DYELLOW}[0]  Skip   — do not pull a quantized variant now${NC}"
    echo ""
    while true; do
        read -rp "  Pick a quantization level (0 to skip): " QCHOICE
        if [[ "$QCHOICE" == "0" ]]; then
            info "Skipped quantization pull."
            return
        fi
        if [[ "$QCHOICE" =~ ^[1-6]$ ]]; then
            local TAG="${QUANT_TAGS[$((QCHOICE-1))]}"
            local PULL_TARGET="${BASE}:${TAG}"
            info "Pulling $PULL_TARGET — this may take a few minutes..."
            if ollama pull "$PULL_TARGET"; then
                ok "Pulled $PULL_TARGET successfully."
                SELECTED_MODEL="$PULL_TARGET"
            else
                warn "Pull failed. The original model was not changed."
            fi
            return
        fi
        warn "Enter a number between 0 and 6."
    done
}

if [[ -n "$TOTAL_VRAM_MIB" && -n "$USED_VRAM_MIB" ]]; then
    FREE_MIB=$(( TOTAL_VRAM_MIB - USED_VRAM_MIB ))
    FREE_GIB=$(awk "BEGIN{printf \"%.1f\", $FREE_MIB  / 1024}")
    TOTAL_GIB=$(awk "BEGIN{printf \"%.1f\", $TOTAL_VRAM_MIB / 1024}")
    USED_GIB=$(awk "BEGIN{printf \"%.1f\", $USED_VRAM_MIB  / 1024}")

    info "GPU : $GPU_NAME"
    info "VRAM: ${TOTAL_GIB} GiB total  |  ${USED_GIB} GiB used  |  ${FREE_GIB} GiB free"

    HIGH_WATER=$(awk "BEGIN{printf \"%d\", $TOTAL_VRAM_MIB * 0.35}")
    if [[ "$USED_VRAM_MIB" -gt "$HIGH_WATER" ]] && [[ -z "$SELECTED_MODEL" ]]; then
        warn "Another process is using more than 35 % of VRAM (${USED_GIB} / ${TOTAL_GIB} GiB)."
        warn "Close GPU-heavy apps before loading a model."
    fi

    if [[ -n "$SELECTED_MODEL" ]]; then
        # Find size for selected model
        MODEL_SIZE=""
        for i in "${!MODEL_NAMES[@]}"; do
            if [[ "${MODEL_NAMES[$i]}" == "$SELECTED_MODEL" ]]; then
                MODEL_SIZE="${MODEL_SIZES[$i]:-}"
                break
            fi
        done

        MODEL_MIB=$(to_mib "$MODEL_SIZE")
        if [[ -n "$MODEL_MIB" ]]; then
            OVERHEAD=$(awk "BEGIN{printf \"%d\", $MODEL_MIB * 0.10}")
            NEEDED=$(( MODEL_MIB + OVERHEAD ))
            NEEDED_GIB=$(awk "BEGIN{printf \"%.1f\", $NEEDED / 1024}")
            BASE_NAME="${SELECTED_MODEL%%:*}"

            info "Model '${SELECTED_MODEL}' requires ~${NEEDED_GIB} GiB (with 10 % overhead)."

            if [[ "$NEEDED" -le "$FREE_MIB" ]]; then
                ok "Model fits comfortably in free VRAM."
            elif [[ "$NEEDED" -le "$TOTAL_VRAM_MIB" ]]; then
                warn "Model needs ${NEEDED_GIB} GiB but only ${FREE_GIB} GiB is free."
                if [[ "$USED_VRAM_MIB" -gt "$HIGH_WATER" ]]; then
                    warn "A large process is hogging VRAM. Free it first, or choose a quantized variant:"
                else
                    warn "Freeing currently-used VRAM may be enough, or pick a smaller quantized variant:"
                fi
                invoke_quant_menu "$BASE_NAME"
            else
                fail "Model ($(awk "BEGIN{printf \"%.1f\", $MODEL_MIB/1024}") GiB) exceeds total VRAM (${TOTAL_GIB} GiB)."
                warn "You must use a quantized (smaller) variant to run this model on your GPU:"
                invoke_quant_menu "$BASE_NAME"
            fi
        else
            info "Could not parse model size — skipping VRAM fit check."
        fi
    fi
else
    warn "No GPU/memory info detected (nvidia-smi, rocm-smi, and Apple Silicon checks all failed)."
    info "Ollama will still run — it will decide automatically whether to use CPU or GPU."
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4 — Export env vars + write .vscode/settings.json
# ─────────────────────────────────────────────────────────────────────────────
header "STEP 4 of 5 — Environment Variables"

export OLLAMA_HOST="$OLLAMA_HOST"
ok "OLLAMA_HOST = '$OLLAMA_HOST'  (exported for this session + shell profile)."
info "Any process started after this point — including VS Code — will inherit OLLAMA_HOST."

if [[ -n "$SELECTED_MODEL" ]]; then
    export OLLAMA_MODEL="$SELECTED_MODEL"
    ok "OLLAMA_MODEL = '$SELECTED_MODEL'."
fi

# Persist to shell profiles with a portable updater.
if command -v python3 &>/dev/null; then
    OLLAMA_HOST_VALUE="$OLLAMA_HOST" OLLAMA_MODEL_VALUE="${SELECTED_MODEL:-}" python3 - <<'PYEOF'
import os
from pathlib import Path

updates = {"OLLAMA_HOST": os.environ["OLLAMA_HOST_VALUE"]}
model = os.environ.get("OLLAMA_MODEL_VALUE", "")
if model:
    updates["OLLAMA_MODEL"] = model

for profile_name in (".bashrc", ".zshrc"):
    path = Path.home() / profile_name
    lines = path.read_text(encoding="utf-8").splitlines() if path.exists() else []
    seen = set()
    next_lines = []

    for line in lines:
        stripped = line.strip()
        replaced = False
        for key, value in updates.items():
            if stripped.startswith(f"export {key}="):
                next_lines.append(f'export {key}="{value}"')
                seen.add(key)
                replaced = True
                break
        if not replaced:
            next_lines.append(line)

    missing = [key for key in updates if key not in seen]
    if missing and next_lines and next_lines[-1].strip():
        next_lines.append("")
    for key in missing:
        next_lines.append(f'export {key}="{updates[key]}"')

    path.write_text("\n".join(next_lines) + "\n", encoding="utf-8")
PYEOF
else
    for PROFILE in "$HOME/.bashrc" "$HOME/.zshrc"; do
        touch "$PROFILE"
        grep -v '^export OLLAMA_HOST=' "$PROFILE" | grep -v '^export OLLAMA_MODEL=' > "${PROFILE}.tmp"
        mv "${PROFILE}.tmp" "$PROFILE"
        printf '\nexport OLLAMA_HOST="%s"\n' "$OLLAMA_HOST" >> "$PROFILE"
        [[ -n "$SELECTED_MODEL" ]] && printf 'export OLLAMA_MODEL="%s"\n' "$SELECTED_MODEL" >> "$PROFILE"
    done
fi

# Write .vscode/settings.json
if [[ -n "$SELECTED_MODEL" ]]; then
    VSCODE_DIR="${WORK_DIR}/.vscode"
    SETTINGS_FILE="${VSCODE_DIR}/settings.json"
    mkdir -p "$VSCODE_DIR"

    if command -v python3 &>/dev/null; then
        python3 - <<PYEOF
import json, os
path = "${SETTINGS_FILE}"
data = {}
if os.path.exists(path):
    try:
        with open(path) as f:
            data = json.load(f)
    except Exception:
        pass

data["continue.models"] = [{
    "title":    "${SELECTED_MODEL}",
    "provider": "ollama",
    "model":    "${SELECTED_MODEL}",
    "apiBase":  "http://${OLLAMA_HOST}"
}]
data["continue.defaultModel"] = "${SELECTED_MODEL}"
data.pop("github.copilot.advanced", None)
with open(path, "w") as f:
    json.dump(data, f, indent=2)
print("  [OK]  Wrote ${SETTINGS_FILE}")
PYEOF
    else
        # Minimal fallback — write a fresh settings.json
        cat > "$SETTINGS_FILE" <<JSON
{
  "continue.models": [
    {
      "title":    "${SELECTED_MODEL}",
      "provider": "ollama",
      "model":    "${SELECTED_MODEL}",
      "apiBase":  "http://${OLLAMA_HOST}"
    }
    ],
    "continue.defaultModel": "${SELECTED_MODEL}"
}
JSON
        ok "Wrote $SETTINGS_FILE (python3 not found — existing keys not preserved)."
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 5 — Open VS Code + explain how to use Ollama as an agent
# ─────────────────────────────────────────────────────────────────────────────
#
#  WHY this step matters:
#  VS Code extensions (Continue, Copilot local-model) discover Ollama by reading
#  OLLAMA_HOST from the environment. Because we set it above in this shell
#  session, launching VS Code from here passes it on automatically — no restart,
#  no manual configuration needed.
#
#  Two ways to use the model once VS Code is open:
#
#   A) GitHub Copilot Chat (only if Copilot Chat is available on this machine)
#      1. Open Chat:        Ctrl+Alt+I
#      2. Click model picker at the bottom of the chat input box
#      3. Look for a "Local", "Ollama", or "Use Local AI" section
#      4. Select your Ollama model if VS Code exposes local models
#
#   B) Continue extension (richer agent + inline-edit experience)
#      1. Install:          Ctrl+Shift+X  →  search "Continue"
#      2. Continue reads OLLAMA_HOST automatically on startup
#      3. Open sidebar:     Ctrl+L  →  chat or use @codebase / @docs
# ─────────────────────────────────────────────────────────────────────────────
header "STEP 5 of 5 — Open VS Code + Register Ollama as Agent"

if ! command -v code &>/dev/null; then
    warn "'code' command not found on PATH."
    info "Enable it in VS Code: Help → Shell Command → Install 'code' command in PATH."
    info "Then re-run this script to open VS Code automatically."
else
    info "Opening VS Code in: $WORK_DIR"
    code "$WORK_DIR"
    ok "VS Code is opening."
    echo ""
    echo -e "  ${CYAN}── How to use Ollama as an AI agent inside VS Code ─────────────────────────${NC}"
    echo -e "  ${CYAN}Option A${NC}  GitHub Copilot Chat (only if Copilot Chat is available)"
    echo -e "  ${GRAY}          1. Open Chat:         Ctrl+Alt+I${NC}"
    echo -e "  ${GRAY}          2. Click model picker at the bottom of the chat input box${NC}"
    echo -e "  ${GRAY}          3. Look for 'Local', 'Ollama', or 'Use Local AI'${NC}"
    echo -e "  ${GRAY}          4. Select your Ollama model if local models are shown${NC}"
    echo ""
    echo -e "  ${CYAN}Option B${NC}  Continue extension  (richer agent / inline-edit experience)"
    echo -e "  ${GRAY}          1. Install: Ctrl+Shift+X  →  search 'Continue'${NC}"
    echo -e "  ${GRAY}          2. Continue reads OLLAMA_HOST automatically on startup${NC}"
    echo -e "  ${GRAY}          3. Open sidebar: Ctrl+L  →  start chatting or use @codebase${NC}"
    echo ""
    echo -e "  ${CYAN}Both options use:${NC}"
    echo -e "  ${GRAY}    OLLAMA_HOST  = http://$OLLAMA_HOST${NC}"
    [[ -n "$SELECTED_MODEL" ]] && echo -e "  ${GRAY}    OLLAMA_MODEL = $SELECTED_MODEL${NC}"
    echo -e "  ${CYAN}────────────────────────────────────────────────────────────────────────────${NC}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# SUMMARY
# ─────────────────────────────────────────────────────────────────────────────
header "Summary"
ok "Ollama API  : http://$OLLAMA_HOST"
[[ -n "$SELECTED_MODEL" ]] && ok "Active model: $SELECTED_MODEL"
info "Useful commands:"
echo -e "  ${GRAY}  ollama list                    # show all local models${NC}"
echo -e "  ${GRAY}  ollama pull <model>            # download a new model${NC}"
echo -e "  ${GRAY}  ollama pull <model>:q4_K_M     # download a 4-bit quantized variant${NC}"
echo -e "  ${GRAY}  ollama rm <model>              # delete a model to free VRAM${NC}"
echo -e "  ${GRAY}  ollama ps                      # show which models are currently loaded${NC}"
echo ""
