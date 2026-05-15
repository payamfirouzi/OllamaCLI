#!/usr/bin/env bash
# =============================================================================
#  patch-agents.sh
#  macOS-first Ollama setup for VS Code local AI.
#
#  What it does:
#    1. Ensures Ollama is installed and running.
#    2. Pulls a model if none are installed, then lets you pick ONE active model.
#    3. Persists OLLAMA_HOST / OLLAMA_MODEL for terminal shells and macOS GUI apps.
#    4. Installs macOS login agents for the environment and Ollama server.
#    5. Configures the Continue extension in .vscode/settings.json.
#    6. Installs Continue when the VS Code CLI is available.
#    7. Opens VS Code from the configured environment.
#
#  Important:
#    - Continue works without GitHub Copilot access.
#    - GitHub Copilot Chat local model support still requires Copilot Chat access
#      and a VS Code build/extension that exposes local models.
# =============================================================================
set -euo pipefail

WORK_DIR="${1:-$PWD}"
OLLAMA_HOST="${2:-127.0.0.1:11434}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELS_FILE="${SCRIPT_DIR}/models.txt"
IS_MAC=false
[[ "$(uname -s)" == "Darwin" ]] && IS_MAC=true

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; WHITE='\033[1;37m'; GRAY='\033[0;37m'; NC='\033[0m'

ok()   { echo -e "  ${GREEN}[OK]${NC}  $*"; }
warn() { echo -e "  ${YELLOW}[!!]${NC}  $*"; }
info() { echo -e "  ${WHITE}[..]${NC}  $*"; }
fail() { echo -e "  ${RED}[XX]${NC}  $*"; }

echo -e "\n${CYAN}=== Ollama Local AI for VS Code ===${NC}"

ensure_ollama_installed() {
    if command -v ollama >/dev/null 2>&1; then
        ok "Ollama CLI found: $(command -v ollama)"
        return
    fi

    warn "Ollama CLI was not found."
    if $IS_MAC && command -v brew >/dev/null 2>&1; then
        read -rp "  Install Ollama with Homebrew now? [Y/n]: " answer
        answer="${answer:-Y}"
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            brew install ollama
            ok "Ollama installed."
            return
        fi
    fi

    if $IS_MAC; then
        open "https://ollama.com/download" >/dev/null 2>&1 || true
    fi
    fail "Install Ollama from https://ollama.com/download, then run this script again."
    exit 1
}

wait_for_ollama() {
    local url="http://${OLLAMA_HOST}"
    for _ in {1..30}; do
        if curl -fsS --max-time 2 "$url" >/dev/null 2>&1; then
            ok "Ollama API is reachable at $url"
            return 0
        fi
        sleep 1
    done
    return 1
}

start_ollama() {
    if wait_for_ollama; then
        return
    fi

    info "Starting Ollama server..."
    if $IS_MAC && [[ -d "/Applications/Ollama.app" ]]; then
        open -g -a Ollama || true
    elif $IS_MAC && command -v brew >/dev/null 2>&1; then
        if ! brew services start ollama >/dev/null 2>&1; then
            nohup ollama serve >/tmp/ollama-serve.log 2>&1 &
        fi
    else
        nohup ollama serve >/tmp/ollama-serve.log 2>&1 &
    fi

    if ! wait_for_ollama; then
        fail "Ollama did not become reachable at http://${OLLAMA_HOST}."
        fail "Try running: ollama serve"
        exit 1
    fi
}

list_models() {
    MODELS=()
    while IFS= read -r line; do
        name="$(echo "$line" | awk '{print $1}')"
        [[ -z "$name" || "$name" == "NAME" ]] && continue
        MODELS+=("$name")
    done < <(ollama list 2>/dev/null || true)
}

recommended_models() {
    RECOMMENDED=()
    if [[ -f "$MODELS_FILE" ]]; then
        while IFS= read -r line; do
            line="${line%%#*}"
            line="$(echo "$line" | xargs)"
            [[ -z "$line" ]] && continue
            RECOMMENDED+=("$line")
        done < "$MODELS_FILE"
    fi
    if [[ ${#RECOMMENDED[@]} -eq 0 ]]; then
        RECOMMENDED=("llama3.1:8b" "qwen2.5-coder:7b" "deepseek-coder:6.7b")
    fi
}

pull_first_model_if_needed() {
    list_models
    if [[ ${#MODELS[@]} -gt 0 ]]; then
        return
    fi

    warn "No Ollama models are installed yet."
    recommended_models
    echo ""
    echo -e "  ${CYAN}Recommended models:${NC}"
    for i in "${!RECOMMENDED[@]}"; do
        printf "    [%2d]  %s\n" "$((i+1))" "${RECOMMENDED[$i]}"
    done
    echo ""

    local pull_model=""
    while [[ -z "$pull_model" ]]; do
        read -rp "  Enter model number to pull: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]]; then
            idx=$((choice - 1))
            if [[ "$idx" -ge 0 && "$idx" -lt "${#RECOMMENDED[@]}" ]]; then
                pull_model="${RECOMMENDED[$idx]}"
            fi
        fi
        [[ -z "$pull_model" ]] && warn "Please enter a number between 1 and ${#RECOMMENDED[@]}."
    done

    info "Pulling $pull_model. This can take a while..."
    ollama pull "$pull_model"
    list_models
}

select_model() {
    list_models
    echo ""
    echo -e "  ${CYAN}Installed Ollama models:${NC}"
    for i in "${!MODELS[@]}"; do
        printf "    [%2d]  %s\n" "$((i+1))" "${MODELS[$i]}"
    done
    echo ""

    SELECTED_MODEL=""
    while [[ -z "$SELECTED_MODEL" ]]; do
        read -rp "  Enter the ONE model number to use in VS Code: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]]; then
            idx=$((choice - 1))
            if [[ "$idx" -ge 0 && "$idx" -lt "${#MODELS[@]}" ]]; then
                SELECTED_MODEL="${MODELS[$idx]}"
            fi
        fi
        [[ -z "$SELECTED_MODEL" ]] && warn "Please enter a number between 1 and ${#MODELS[@]}."
    done
    ok "Selected model: $SELECTED_MODEL"
}

persist_environment() {
    export OLLAMA_HOST="$OLLAMA_HOST"
    export OLLAMA_MODEL="$SELECTED_MODEL"

    if command -v python3 >/dev/null 2>&1; then
        OLLAMA_HOST_VALUE="$OLLAMA_HOST" OLLAMA_MODEL_VALUE="$SELECTED_MODEL" python3 - <<'PYEOF'
import os
from pathlib import Path

updates = {
    "OLLAMA_HOST": os.environ["OLLAMA_HOST_VALUE"],
    "OLLAMA_MODEL": os.environ["OLLAMA_MODEL_VALUE"],
}

for profile_name in (".zshrc", ".bashrc"):
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
        for profile in "$HOME/.zshrc" "$HOME/.bashrc"; do
            touch "$profile"
            grep -v '^export OLLAMA_HOST=' "$profile" | grep -v '^export OLLAMA_MODEL=' > "${profile}.tmp"
            mv "${profile}.tmp" "$profile"
            printf '\nexport OLLAMA_HOST="%s"\n' "$OLLAMA_HOST" >> "$profile"
            printf 'export OLLAMA_MODEL="%s"\n' "$SELECTED_MODEL" >> "$profile"
        done
    fi
    ok "Saved OLLAMA_HOST and OLLAMA_MODEL to ~/.zshrc and ~/.bashrc"

    if $IS_MAC; then
        launchctl setenv OLLAMA_HOST "$OLLAMA_HOST"
        launchctl setenv OLLAMA_MODEL "$SELECTED_MODEL"
        ok "Set OLLAMA_HOST / OLLAMA_MODEL for macOS GUI apps via launchctl"

        local agents_dir="$HOME/Library/LaunchAgents"
        local plist_file="$agents_dir/com.olamacli.vscode-env.plist"
        mkdir -p "$agents_dir"
        cat > "$plist_file" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.olamacli.vscode-env</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/sh</string>
        <string>-c</string>
        <string>/bin/launchctl setenv OLLAMA_HOST "$OLLAMA_HOST"; /bin/launchctl setenv OLLAMA_MODEL "$SELECTED_MODEL"</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
PLIST
        launchctl unload "$plist_file" >/dev/null 2>&1 || true
        launchctl load "$plist_file" >/dev/null 2>&1 || true
        ok "Installed login LaunchAgent for VS Code/Ollama environment"
    fi
}

install_ollama_server_login_agent() {
    if ! $IS_MAC; then
        return
    fi

    local ollama_bin
    ollama_bin="$(command -v ollama)"
    local agents_dir="$HOME/Library/LaunchAgents"
    local plist_file="$agents_dir/com.olamacli.ollama-serve.plist"
    mkdir -p "$agents_dir"

    cat > "$plist_file" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.olamacli.ollama-serve</string>
    <key>ProgramArguments</key>
    <array>
        <string>$ollama_bin</string>
        <string>serve</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/ollama-serve.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/ollama-serve.err</string>
</dict>
</plist>
PLIST
    launchctl unload "$plist_file" >/dev/null 2>&1 || true
    launchctl load "$plist_file" >/dev/null 2>&1 || true
    ok "Installed login LaunchAgent for the Ollama server"
}

write_vscode_settings() {
    local vscode_dir="${WORK_DIR}/.vscode"
    local settings_file="${vscode_dir}/settings.json"
    mkdir -p "$vscode_dir"

    if command -v python3 >/dev/null 2>&1; then
        SETTINGS_FILE="$settings_file" SELECTED_MODEL="$SELECTED_MODEL" OLLAMA_HOST="$OLLAMA_HOST" python3 - <<'PYEOF'
import json
import os

path = os.environ["SETTINGS_FILE"]
model = os.environ["SELECTED_MODEL"]
host = os.environ["OLLAMA_HOST"]

data = {}
if os.path.exists(path):
    try:
        with open(path, encoding="utf-8") as file:
            data = json.load(file)
    except Exception:
        data = {}

# Copilot does not read this old/custom key; remove it to avoid confusion.
data.pop("github.copilot.advanced", None)

# Continue extension configuration. This is the reliable local-agent path.
data["continue.models"] = [{
    "title": model,
    "provider": "ollama",
    "model": model,
    "apiBase": f"http://{host}"
}]
data["continue.defaultModel"] = model

with open(path, "w", encoding="utf-8") as file:
    json.dump(data, file, indent=4)
    file.write("\n")
print(f"  [OK]  Wrote {path} for Continue ({model})")
PYEOF
    else
        warn "python3 not found; writing a minimal .vscode/settings.json."
        cat > "$settings_file" <<JSON
{
    "continue.models": [
        {
            "title": "${SELECTED_MODEL}",
            "provider": "ollama",
            "model": "${SELECTED_MODEL}",
            "apiBase": "http://${OLLAMA_HOST}"
        }
    ],
    "continue.defaultModel": "${SELECTED_MODEL}"
}
JSON
        ok "Wrote $settings_file"
    fi
}

install_continue_if_possible() {
    if command -v code >/dev/null 2>&1; then
        info "Installing/updating Continue extension in VS Code..."
        code --install-extension Continue.continue --force >/dev/null 2>&1 || warn "Could not install Continue automatically. Install it from Extensions if needed."
        return
    fi

    if $IS_MAC && [[ -x "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code" ]]; then
        info "Installing/updating Continue extension using VS Code.app CLI..."
        "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code" --install-extension Continue.continue --force >/dev/null 2>&1 || warn "Could not install Continue automatically."
        return
    fi

    warn "VS Code 'code' CLI not found; install Continue manually from Extensions."
}

open_vscode() {
    if command -v code >/dev/null 2>&1; then
        info "Opening VS Code in $WORK_DIR"
        OLLAMA_HOST="$OLLAMA_HOST" OLLAMA_MODEL="$SELECTED_MODEL" code "$WORK_DIR"
    elif $IS_MAC && [[ -d "/Applications/Visual Studio Code.app" ]]; then
        info "Opening VS Code.app in $WORK_DIR"
        open -a "Visual Studio Code" "$WORK_DIR"
    else
        warn "VS Code was configured, but I could not open it automatically."
    fi
}

ensure_ollama_installed
start_ollama
pull_first_model_if_needed
select_model
persist_environment
install_ollama_server_login_agent
write_vscode_settings
install_continue_if_possible
open_vscode

echo ""
echo -e "${CYAN}=== Done ===${NC}"
echo -e "  ${GREEN}Active local model:${NC} ${SELECTED_MODEL}"
echo -e "  ${GREEN}Ollama API:${NC} http://${OLLAMA_HOST}"
echo ""
echo -e "  ${CYAN}Use it now:${NC}"
echo -e "  ${GRAY}1. In VS Code, open Continue from the sidebar.${NC}"
echo -e "  ${GRAY}2. Use ${SELECTED_MODEL} with chat, @codebase, or edits.${NC}"
echo ""
echo -e "  ${CYAN}About GitHub Copilot Chat:${NC}"
echo -e "  ${GRAY}This script sets OLLAMA_HOST correctly for Copilot local-model detection.${NC}"
echo -e "  ${GRAY}If Copilot Chat is unavailable on this Mac, VS Code cannot show local models inside Copilot.${NC}"
echo -e "  ${GRAY}Continue is the no-Copilot-access local AI route and has been configured.${NC}"
echo ""
