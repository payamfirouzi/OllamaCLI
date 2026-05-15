# OlamaCLI — Local AI Coding Environment

Run a local Ollama language-model server and connect it to VS Code (GitHub
Copilot Chat or the Continue extension) in a single command.

Works on **Windows** (PowerShell) and **Linux / macOS** (Bash).

---

## Prerequisites

| Tool | Where to get it | Required? |
|------|----------------|-----------|
| **Ollama** | https://ollama.com/download | ✅ Required |
| **VS Code** | https://code.visualstudio.com | ✅ Required |
| **`code` CLI** | VS Code → Help → Shell Command → *Install 'code' command in PATH* | ✅ Required |
| `nvidia-smi` | Installed with NVIDIA CUDA drivers | Recommended (GPU check) |
| `rocm-smi` | Installed with AMD ROCm drivers | Recommended (AMD GPU check) |
| `jq` | `apt install jq` / `brew install jq` | Optional (better JSON parsing on Linux/macOS) |
| `python3` | https://python.org | Optional (safe settings.json merge on Linux/macOS) |

---

## Quick Start

### Windows (PowerShell)

Open a PowerShell terminal and run:

```powershell
# From the workspace root
& .\OlamaCLI\Start-OllamaEnv.ps1
```

To open a specific folder instead of the current directory:

```powershell
& .\OlamaCLI\Start-OllamaEnv.ps1 -WorkDir "C:\MyProject"
```

### Linux / macOS (Bash)

Make the script executable once, then run it:

```bash
chmod +x OlamaCLI/Start-OllamaEnv.sh
./OlamaCLI/Start-OllamaEnv.sh
```

To open a specific folder:

```bash
./OlamaCLI/Start-OllamaEnv.sh /home/user/my-project
```

---

## What the Script Does — Step by Step

### Step 1 — Ollama Server
Checks whether an `ollama` process is already running.
If not, it starts `ollama serve` silently in the background and polls the
API every second for up to 10 seconds to confirm it is reachable.

### Step 2 — Model Selection
Fetches your locally pulled models with `ollama list` and prints a numbered
menu. Enter the number of the model you want to use. Press **Enter** to skip
model selection and continue with whatever Ollama has loaded.

```
Locally available models:
    [ 1]  llama3:latest                              4.7 GB
    [ 2]  codellama:7b                               3.8 GB
    [ 3]  mistral:7b-instruct                        4.1 GB

  Enter model number to activate (or press Enter to skip): 2
```

If no models are installed yet, pull one first:

```bash
ollama pull llama3          # general purpose
ollama pull codellama       # code-focused
ollama pull mistral         # fast, high quality
ollama pull deepseek-coder  # advanced code model
```

### Step 3 — VRAM Check and Quantization Menu
The script reads your GPU's total / used / free VRAM using `nvidia-smi` or
`rocm-smi`.

**Three possible outcomes:**

| Situation | What happens |
|-----------|-------------|
| Model fits in free VRAM | Confirmed with a green OK message |
| Model fits in total VRAM but not free | Warning: another process is using memory; quantization menu offered |
| Model is larger than total VRAM | Error: model cannot run on this GPU; quantization menu required |

**Quantization menu** — shown automatically when needed:

```
  [!!]  Model (8.1 GiB) exceeds total VRAM (6.0 GiB).

    [1]  Q8_0   — 8-bit,  ~100 % quality, ~12 % smaller  (best for large VRAM)
    [2]  Q6_K   — 6-bit,  ~99 % quality,  ~35 % smaller
    [3]  Q5_K_M — 5-bit,  ~97 % quality,  ~41 % smaller  (recommended)
    [4]  Q4_K_M — 4-bit,  ~95 % quality,  ~50 % smaller  (most popular)
    [5]  Q3_K_M — 3-bit,  ~91 % quality,  ~62 % smaller
    [6]  Q2_K   — 2-bit,  ~85 % quality,  ~75 % smaller  (last resort)
    [0]  Skip   — do not pull a quantized variant now

  Pick a quantization level (0 to skip): 4
```

Choosing a number runs `ollama pull <model>:q4_K_M` (or whichever level you
selected) immediately. The new quantized model becomes the active selection.

> **Rule of thumb:** Q4_K_M is the best trade-off between quality and VRAM
> usage for most users. Only go lower (Q3/Q2) if Q4 still does not fit.

### Step 4 — Environment Variables
Sets two variables so every VS Code extension finds the server without any
manual configuration:

| Variable | Value | Effect |
|----------|-------|--------|
| `OLLAMA_HOST` | `127.0.0.1:11434` | Points extensions to the local API |
| `OLLAMA_MODEL` | *(chosen model name)* | Pre-selects the model in Continue |

On **Windows** these are written to the Windows user profile (permanent).  
On **Linux / macOS** they are appended / updated in `~/.bashrc` and `~/.zshrc`.

On **macOS**, the quick patch script also runs `launchctl setenv` so GUI apps
started from Finder, Spotlight, or the Dock can see `OLLAMA_HOST`. This matters
because VS Code launched from the Dock does not automatically read shell files.
It also creates a login LaunchAgent so those GUI environment variables are
restored after reboot, and another login LaunchAgent so `ollama serve` starts
when you log in.

The script writes `.vscode/settings.json` inside the opened workspace with the
selected model for the **Continue** extension. GitHub Copilot Chat does not use a
workspace `settings.json` key for Ollama models; when supported, it detects local
models from the `OLLAMA_HOST` environment variable.

### Step 5 — Open VS Code and Use Ollama as an Agent
VS Code is launched from the script process, which already has `OLLAMA_HOST`
in its environment. The new VS Code window inherits the variable immediately —
no system restart is needed.

#### Option A — GitHub Copilot Chat (only if Copilot Chat is available)
1. Open Chat: **Ctrl+Alt+I**
2. Click the **model picker** at the bottom of the chat input box
3. Look for a **Local**, **Ollama**, or **Use Local AI** section
4. Chat normally — all requests go to `http://127.0.0.1:11434`

#### Option B — Continue Extension (recommended for full agent experience)
1. Install **Continue** from the Extensions Marketplace: **Ctrl+Shift+X** → search `Continue`
2. Continue reads `OLLAMA_HOST` automatically on startup
3. Open the Continue sidebar: **Ctrl+L**
4. Use plain chat, `@codebase` for codebase-wide questions, or `@docs` for documentation lookup

---

## macOS: One Command Local AI Setup

On the Mac where you do not have GitHub Copilot access, use the Bash patch
script. It configures Ollama for VS Code and installs/configures **Continue**,
which gives you a local agent experience without needing Copilot access.

From the workspace root on macOS:

```bash
bash OlamaCLI/patch-agents.sh
```

The script handles:
1. Checking that Ollama is installed, with a Homebrew install option if needed.
2. Starting the Ollama server.
3. Pulling a model if none are installed yet.
4. Letting you choose **one** active model.
5. Persisting `OLLAMA_HOST` and `OLLAMA_MODEL` for terminal shells.
6. Running `launchctl setenv` so VS Code launched as a macOS GUI app can see Ollama.
7. Installing a login LaunchAgent so the GUI environment survives reboot.
8. Installing a login LaunchAgent so the Ollama server starts after reboot.
9. Writing the selected model into `.vscode/settings.json` for Continue.
10. Installing/updating the Continue extension when the VS Code `code` CLI is available.
11. Opening VS Code in the configured workspace.

After it opens VS Code, use **Continue** from the sidebar. Your selected Ollama
model is pre-configured there, and you can use chat, `@codebase`, and edits.

### About GitHub Copilot Chat on macOS

The script sets the environment correctly for Copilot local-model detection:
`OLLAMA_HOST=127.0.0.1:11434`.

But if you do **not** have GitHub Copilot Chat access on that Mac, the script
cannot make Copilot Chat appear or unlock Copilot's model picker. In that case,
Continue is the correct local AI route.

If Copilot Chat is available on the Mac, fully close and reopen VS Code after
running the script, then open Chat and check the model picker for a **Local** or
**Ollama** section.

---

## Windows / Linux Quick Patch

If you already have models installed and want to choose one model for VS Code
without running the full setup script, use the dedicated patch scripts:

### Windows (PowerShell)

```powershell
.\OlamaCLI\patch-agents.ps1
# optional: target a specific workspace folder
.\OlamaCLI\patch-agents.ps1 -WorkDir "C:\MyProject"
```

### Linux / macOS (Bash)

```bash
bash OlamaCLI/patch-agents.sh
# optional: target a specific workspace folder
bash OlamaCLI/patch-agents.sh /home/user/my-project
```

Both scripts:
1. Read models from `ollama list` automatically.
2. Let you choose **one** active model.
3. Persist `OLLAMA_HOST` so VS Code can find the Ollama server.
4. Write `.vscode/settings.json` for **Continue**.
5. Print step-by-step instructions for using the model inside VS Code.

### How to open the models in VS Code after patching

**Copilot Chat (built-in)**

1. **Fully close and reopen VS Code** so it can see `OLLAMA_HOST`.
2. Open Chat: `Ctrl+Alt+I`
3. Click the **model-picker** at the bottom of the chat input.
4. Look for a **Local** or **Ollama** section and select the chosen model.
5. Optionally switch the mode selector to **Agent** for tool-use / multi-step tasks.

**Continue extension (full agent experience)**

1. Install Continue: `Ctrl+Shift+X` → search `Continue`
2. Open the sidebar: `Ctrl+L`
3. Click the model name at the top to switch between models.
4. Use `@codebase`, `@docs`, or plain chat.

> **Tip:** If local models do not appear in Copilot Chat, first confirm that
> Copilot Chat itself is available on that machine. Without Copilot Chat access,
> use Continue; it is configured by the script and does not require Copilot.

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `ollama: command not found` | Install Ollama and ensure it is on PATH |
| `code: command not found` | VS Code → Help → Shell Command → Install 'code' |
| Server started but not reachable | Check that no firewall is blocking port 11434; try `curl http://127.0.0.1:11434` |
| Model not showing in Copilot Chat | Ensure VS Code was opened *from this script* (so it inherits OLLAMA_HOST); restart VS Code if needed |
| Out-of-memory crash when loading model | Re-run the script and select a lower quantization level from the menu |
| `nvidia-smi` not found | Install NVIDIA drivers; on Linux add `/usr/bin` to PATH |

---

## Useful Ollama Commands

```bash
ollama list                    # show all locally downloaded models
ollama pull <model>            # download a new model
ollama pull <model>:q4_K_M     # download a specific quantized variant
ollama rm <model>              # delete a model to free disk / VRAM
ollama ps                      # show which models are currently loaded in memory
ollama stop <model>            # unload a model from VRAM without deleting it
```

---

## Files in This Folder

| File | Purpose |
|------|---------|
| `Start-OllamaEnv.ps1` | Windows PowerShell full-setup script (server + model pick + VRAM check + VS Code launch) |
| `Start-OllamaEnv.sh` | Linux / macOS Bash full-setup script |
| `patch-agents.ps1` | Windows PowerShell quick-patch: registers all installed models as VS Code agents |
| `patch-agents.sh` | Linux / macOS Bash quick-patch: registers all installed models as VS Code agents |
| `models.txt` | List of models to auto-pull when running the `.sh` on macOS/Linux |
| `OlamaCLI.md` | This documentation |

---

## models.txt — Auto-Pull List (macOS/Linux)

When `Start-OllamaEnv.sh` runs on macOS or Linux it reads `OlamaCLI/models.txt`
and pulls any models that are not already installed. Models that are already
present are skipped.

Edit `models.txt` to customise which models are available after a fresh clone:

```
# General purpose
llama3.1:8b
mistral:7b-instruct

# Code-focused
codellama:7b
deepseek-coder:6.7b

# Specific quantization
llama3.1:q4_K_M
```

**M5 Pro 24 GB guidance:**
Apple Silicon unified memory is shared between CPU and GPU. Ollama uses the
Metal backend and can access the full 24 GB pool. Models up to ~16 GB leave
comfortable headroom for macOS and other apps. The pre-filled `models.txt`
targets that range.

