<#
.SYNOPSIS
    Pick one Ollama model and register it as a VS Code agent.

.DESCRIPTION
    1. Lists locally-installed Ollama models and lets you pick ONE.
    2. Sets OLLAMA_HOST permanently in the Windows user profile
       (this is what GitHub Copilot Chat uses to detect local models —
        no settings.json key is needed for Copilot itself).
    3. Writes .vscode/settings.json for the Continue extension only.
    4. Prints the exact steps to open the model in VS Code.

.PARAMETER WorkDir
    Workspace folder to write .vscode/settings.json into.
    Defaults to the current directory.

.PARAMETER OllamaHost
    host:port the Ollama API listens on. Defaults to 127.0.0.1:11434.

.EXAMPLE
    .\OlamaCLI\patch-agents.ps1
    .\OlamaCLI\patch-agents.ps1 -WorkDir "C:\MyProject"
#>

[CmdletBinding()]
param(
    [string] $WorkDir    = (Get-Location).Path,
    [string] $OllamaHost = "127.0.0.1:11434"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Ok   ([string]$t) { Write-Host "  [OK]  $t" -ForegroundColor Green  }
function Write-Warn ([string]$t) { Write-Host "  [!!]  $t" -ForegroundColor Yellow }
function Write-Info ([string]$t) { Write-Host "  [··]  $t" -ForegroundColor White  }
function Write-Fail ([string]$t) { Write-Host "  [XX]  $t" -ForegroundColor Red    }

Write-Host "`n━━━  Ollama Agent Patch  ━━━" -ForegroundColor Cyan

# ── 1. Verify ollama is installed ─────────────────────────────────────────────
if (-not (Get-Command ollama -ErrorAction SilentlyContinue)) {
    Write-Fail "ollama not found on PATH. Install from https://ollama.com/download"
    exit 1
}

# ── 2. List installed models and let user pick ONE ────────────────────────────
Write-Info "Reading installed models from 'ollama list'..."

$rawLines   = ollama list 2>&1
$modelNames = @()
foreach ($line in $rawLines) {
    if ($line -match '^\s*NAME' -or [string]::IsNullOrWhiteSpace($line)) { continue }
    $parts = $line -split '\s+'
    if ($parts.Count -ge 1 -and $parts[0]) { $modelNames += $parts[0] }
}

if ($modelNames.Count -eq 0) {
    Write-Fail "No models found. Pull one first:  ollama pull llama3.1"
    exit 1
}

Write-Host ""
Write-Host "  Locally available models:" -ForegroundColor Cyan
for ($i = 0; $i -lt $modelNames.Count; $i++) {
    Write-Host ("    [{0,2}]  {1}" -f ($i + 1), $modelNames[$i]) -ForegroundColor Gray
}
Write-Host ""

$selectedModel = $null
while (-not $selectedModel) {
    $input = Read-Host "  Enter model number"
    if ($input -match '^\d+$') {
        $idx = [int]$input - 1
        if ($idx -ge 0 -and $idx -lt $modelNames.Count) {
            $selectedModel = $modelNames[$idx]
        }
    }
    if (-not $selectedModel) {
        Write-Warn "Please enter a number between 1 and $($modelNames.Count)."
    }
}
Write-Ok "Selected: $selectedModel"

# ── 3. Set OLLAMA_HOST (this is what Copilot Chat reads — not settings.json) ──
$env:OLLAMA_HOST = $OllamaHost
[System.Environment]::SetEnvironmentVariable("OLLAMA_HOST", $OllamaHost, "User")
Write-Ok "OLLAMA_HOST = '$OllamaHost'  (session + Windows user profile)"
Write-Info "Copilot Chat detects local models via this env var — no settings key needed."

# ── 4. Write .vscode/settings.json for Continue extension only ───────────────
$vscodeDir    = Join-Path $WorkDir ".vscode"
$settingsFile = Join-Path $vscodeDir "settings.json"

if (-not (Test-Path $vscodeDir)) {
    New-Item -ItemType Directory -Path $vscodeDir | Out-Null
}

# Load existing settings and preserve unrelated keys
$data = if (Test-Path $settingsFile) {
    try { Get-Content $settingsFile -Raw | ConvertFrom-Json }
    catch { [PSCustomObject]@{} }
} else { [PSCustomObject]@{} }

# Remove the old (wrong) Copilot key if present
$data.PSObject.Properties.Remove("github.copilot.advanced")

# Continue extension — single selected model
$data | Add-Member -Force -NotePropertyName "continue.models" -NotePropertyValue @(
    [PSCustomObject]@{
        title    = $selectedModel
        provider = "ollama"
        model    = $selectedModel
        apiBase  = "http://$OllamaHost"
    }
)
$data | Add-Member -Force -NotePropertyName "continue.defaultModel" -NotePropertyValue $selectedModel

$data | ConvertTo-Json -Depth 10 | Set-Content -Path $settingsFile -Encoding UTF8
Write-Ok "Wrote $settingsFile  (Continue: $selectedModel)"

# ── 5. Print usage instructions ───────────────────────────────────────────────
Write-Host ""
Write-Host "━━━  Done! How to use '$selectedModel' in VS Code  ━━━" -ForegroundColor Cyan
Write-Host ""
Write-Host "  GitHub Copilot Chat (built-in)" -ForegroundColor Cyan
Write-Host "    1. FULLY close and reopen VS Code (so it inherits OLLAMA_HOST)." -ForegroundColor Yellow
Write-Host "    2. Open Chat:  Ctrl+Alt+I" -ForegroundColor Gray
Write-Host "    3. Click the model-picker at the bottom of the chat input." -ForegroundColor Gray
Write-Host "    4. Look for a 'Local' or 'Ollama' section  ->  pick $selectedModel" -ForegroundColor Gray
Write-Host ""
Write-Host "  Continue extension (full agent + @codebase)" -ForegroundColor Cyan
Write-Host "    1. Install Continue:  Ctrl+Shift+X  ->  search 'Continue'" -ForegroundColor Gray
Write-Host "    2. Open sidebar:  Ctrl+L  ->  $selectedModel is pre-configured." -ForegroundColor Gray
Write-Host ""
Write-Host "  Active model : $selectedModel" -ForegroundColor Cyan
Write-Host "  API endpoint : http://$OllamaHost" -ForegroundColor Cyan
Write-Host ""
Write-Host ""
Write-Host "  Option B — Continue extension (full agent + @codebase)" -ForegroundColor Cyan
Write-Host "    1. Install Continue:  Ctrl+Shift+X  ->  search 'Continue'" -ForegroundColor Gray
Write-Host "    2. Open the sidebar:  Ctrl+L" -ForegroundColor Gray
Write-Host "    3. Click the model name at the top to switch between models." -ForegroundColor Gray
Write-Host "    4. Use @codebase, @docs, or plain chat." -ForegroundColor Gray
Write-Host ""
Write-Host "  Registered models:" -ForegroundColor Cyan
foreach ($m in $modelNames) { Write-Host "    • $m" -ForegroundColor Gray }
Write-Host "  API endpoint: http://$OllamaHost" -ForegroundColor Cyan
Write-Host ""
