# OllamaCLI

macOS-first local AI setup for VS Code using Ollama and Continue.

OllamaCLI helps you use a local Ollama model as a practical replacement when cloud AI quotas are unavailable or exhausted. It configures VS Code so Continue can talk directly to your local model, without consuming GitHub Copilot tokens.

> Status: macOS is the supported path right now. Windows support is pending.

## What It Does

The main macOS script, `patch-agents.sh`, handles the local setup end to end:

- Checks whether Ollama is installed.
- Starts the Ollama server.
- Pulls a model if none are installed yet.
- Lets you choose one active model.
- Persists `OLLAMA_HOST` and `OLLAMA_MODEL` for terminal shells.
- Uses `launchctl` so VS Code launched from Finder, Spotlight, or the Dock can see Ollama.
- Installs login LaunchAgents so the environment and Ollama server survive reboot.
- Writes `.vscode/settings.json` for the Continue extension.
- Installs or updates Continue when the VS Code `code` CLI is available.
- Opens VS Code in the configured workspace.

## Why Continue Instead Of Copilot?

Continue talks directly to Ollama, so it does not use Copilot cloud tokens.

GitHub Copilot Chat local-model support, when available, still depends on Copilot Chat being available in your VS Code/account. This project sets the correct `OLLAMA_HOST` environment variable, but it cannot unlock Copilot Chat or bypass Copilot account limits.

For a reliable local workflow, use Continue.

## Quick Start On macOS

From your workspace root:

```bash
bash OlamaCLI/patch-agents.sh
```

Then follow the prompts:

1. Install Ollama if the script offers to do so.
2. Choose one installed model, or pull one if none exist yet.
3. Let the script open VS Code.
4. Open the Continue sidebar in VS Code.
5. Use your selected local model for chat, edits, and `@codebase`.

After the first run, you normally just open VS Code. The script installs login agents so Ollama and the required environment variables are restored after login.

## Changing The Active Model

Run the same script again:

```bash
bash OlamaCLI/patch-agents.sh
```

Pick a different model from the menu. The selected model becomes the new default for Continue.

## Pulling More Models

The `models.txt` file contains the default recommended pull list plus optional commented Q4 examples.

You can pull a model manually:

```bash
ollama pull qwen2.5-coder:7b
```

Or edit `models.txt`, uncomment the model you want, then use the setup scripts that read that file.

Q4 entries are commented on purpose. Uncomment them only when you want to try a quantized model. Ollama tag names can vary by model page, so if a tag fails, check the model page on Ollama and adjust the tag.

## Files

| File | Purpose |
| --- | --- |
| `patch-agents.sh` | Supported macOS setup script for local VS Code AI through Ollama and Continue |
| `Start-OllamaEnv.sh` | Full Bash setup script with model selection and VRAM/unified-memory checks |
| `models.txt` | Recommended models and optional commented Q4 entries |
| `OlamaCLI.md` | Detailed notes and extended documentation |
| `patch-agents.ps1` | Windows experiment, pending support |
| `Start-OllamaEnv.ps1` | Windows experiment, pending support |

## Requirements

- macOS
- VS Code
- Ollama
- Continue extension for VS Code
- Optional: Homebrew, for automatic Ollama installation
- Optional: VS Code `code` CLI, for automatic Continue installation and opening VS Code

## macOS LaunchAgents

The setup script creates these user LaunchAgents:

- `~/Library/LaunchAgents/com.olamacli.vscode-env.plist`
- `~/Library/LaunchAgents/com.olamacli.ollama-serve.plist`

They make the setup persistent after reboot by restoring VS Code environment variables and starting `ollama serve` at login.

## Windows Status

Windows support is pending. PowerShell scripts are present as experimental work, but the documented supported workflow is macOS.

## License

No license has been selected yet. Until a license is added, all rights are reserved by the repository owner.
