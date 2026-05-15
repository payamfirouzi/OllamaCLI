<#
.SYNOPSIS
    Automates a local AI coding environment using Ollama + VS Code.

.DESCRIPTION
    1. Ensures the Ollama server is running — starts it in a hidden background
       window if it is not, then waits for the API to become reachable.
    2. Lists every locally-pulled model and lets you pick one interactively.
    3. Checks VRAM availability:
         • Reports total / used / free VRAM.
         • Warns when another process is already hogging GPU memory.
         • If the chosen model does not fit, offers an interactive quantization
           menu so you can pull a smaller variant immediately.
    4. Exports OLLAMA_HOST (and OLLAMA_MODEL) for both the current process and
       the Windows user profile, so every VS Code extension can find the server
       without manual configuration.
    5. Opens VS Code in the target directory AND registers Ollama as a local
       language-model provider that GitHub Copilot / Continue can use as an
       agent — explained step by step at launch.

.PARAMETER WorkDir
    Folder to open in VS Code. Defaults to the current working directory.

.PARAMETER OllamaHost
    host:port the Ollama API listens on. Defaults to 127.0.0.1:11434.

.NOTES
    Required : ollama CLI on PATH.
    For VRAM : nvidia-smi (NVIDIA) or rocm-smi (AMD) on PATH.
    For VS Code launch : the 'code' CLI must be on PATH
                         (VS Code → Help → Shell Command → Install 'code').
#>

[CmdletBinding()]
param(
    [string] $WorkDir    = (Get-Location).Path,
    [string] $OllamaHost = "127.0.0.1:11434"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ─────────────────────────────────────────────────────────────────────────────
# HELPERS
# ─────────────────────────────────────────────────────────────────────────────
function Write-Header([string]$text) {
    Write-Host "`n━━━  $text  ━━━" -ForegroundColor Cyan
}
function Write-Ok([string]$text)   { Write-Host "  [OK]  $text" -ForegroundColor Green  }
function Write-Warn([string]$text) { Write-Host "  [!!]  $text" -ForegroundColor Yellow }
function Write-Info([string]$text) { Write-Host "  [··]  $text" -ForegroundColor White  }
function Write-Fail([string]$text) { Write-Host "  [XX]  $text" -ForegroundColor Red    }

function ConvertTo-MiB([string]$sizeStr) {
    if ($sizeStr -match '([\d\.]+)\s*(GB|GiB)') { return [math]::Round([double]$Matches[1] * 1024) }
    if ($sizeStr -match '([\d\.]+)\s*(MB|MiB)') { return [math]::Round([double]$Matches[1]) }
    return $null
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1 — Ensure Ollama server is running
# ─────────────────────────────────────────────────────────────────────────────
Write-Header "STEP 1 of 5 — Ollama Server"

$_ollamaCmd = Get-Command ollama -ErrorAction SilentlyContinue
$ollamaExe  = if ($_ollamaCmd) { $_ollamaCmd.Source } else { $null }
if (-not $ollamaExe) {
    Write-Fail "ollama executable not found on PATH."
    Write-Info  "Install from https://ollama.com/download, then re-run."
    exit 1
}

$ollamaRunning = Get-Process -Name "ollama" -ErrorAction SilentlyContinue
if ($ollamaRunning) {
    Write-Ok "Ollama process already running (PID $($ollamaRunning.Id))."
} else {
    Write-Info "Starting ollama serve in a hidden background window..."
    Start-Process -FilePath $ollamaExe -ArgumentList "serve" -WindowStyle Hidden -PassThru | Out-Null

    $apiUrl = "http://$OllamaHost"
    $ready  = $false
    for ($i = 1; $i -le 10; $i++) {
        Start-Sleep -Seconds 1
        try { $null = Invoke-RestMethod -Uri $apiUrl -TimeoutSec 2 -ErrorAction Stop; $ready = $true; break }
        catch { <# not ready yet #> }
    }
    if ($ready) { Write-Ok "Server started and reachable at $apiUrl." }
    else        { Write-Warn "Server started but did not respond within 10 s. Continuing." }
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2 — List pulled models and let the user select one
# ─────────────────────────────────────────────────────────────────────────────
Write-Header "STEP 2 of 5 — Model Selection"

try {
    $listJson  = ollama list --format json 2>$null | ConvertFrom-Json -ErrorAction Stop
    $modelObjs = @($listJson.models)
} catch {
    $rawLines  = ollama list 2>&1
    $modelObjs = $rawLines | Select-Object -Skip 1 | Where-Object { $_ -match '\S' } |
                 ForEach-Object {
                     $cols = ($_ -split '\s{2,}')
                     [PSCustomObject]@{
                         name = $cols[0].Trim()
                         size = if ($cols.Count -ge 4) { $cols[3].Trim() } else { "?" }
                     }
                 }
}

$selectedModel = $null
if (-not $modelObjs -or $modelObjs.Count -eq 0) {
    Write-Warn "No models found locally."
    Write-Info "Pull one first:  ollama pull llama3   |  ollama pull codellama  |  ollama pull mistral"
} else {
    Write-Info "Locally available models:"
    for ($i = 0; $i -lt $modelObjs.Count; $i++) {
        $sz = if ($modelObjs[$i].size) { $modelObjs[$i].size } else { "?" }
        Write-Host ("    [{0,2}]  {1,-42} {2}" -f ($i + 1), $modelObjs[$i].name, $sz) -ForegroundColor White
    }
    Write-Host ""
    $choice = $null
    do {
        $raw    = Read-Host "  Enter model number to activate (or press Enter to skip)"
        if ($raw -eq "") { break }
        $choice = $raw -as [int]
    } while ($null -eq $choice -or $choice -lt 1 -or $choice -gt $modelObjs.Count)

    if ($choice -ge 1 -and $choice -le $modelObjs.Count) {
        $selectedModel = $modelObjs[$choice - 1].name
        Write-Ok "Selected model: $selectedModel"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3 — VRAM check + interactive quantization option
# ─────────────────────────────────────────────────────────────────────────────
Write-Header "STEP 3 of 5 — VRAM / Memory Check"

$totalVramMiB = $null; $usedVramMiB = $null; $gpuName = "Unknown GPU"

$nvidiaSmi = Get-Command "nvidia-smi" -ErrorAction SilentlyContinue
if ($nvidiaSmi) {
    try {
        $nvOut = & nvidia-smi --query-gpu=name,memory.total,memory.used --format=csv,noheader,nounits 2>$null
        if ($nvOut) {
            $parts        = ($nvOut -split ',')
            $gpuName      = $parts[0].Trim()
            $totalVramMiB = [int]$parts[1].Trim()
            $usedVramMiB  = [int]$parts[2].Trim()
        }
    } catch { Write-Warn "nvidia-smi query failed: $_" }
}

if (-not $totalVramMiB) {
    $rocmSmi = Get-Command "rocm-smi" -ErrorAction SilentlyContinue
    if ($rocmSmi) {
        try {
            $rocmOut = & rocm-smi --showmeminfo vram --csv 2>$null
            $line = ($rocmOut | Select-Object -Skip 1 | Where-Object { $_ -match '\d' } | Select-Object -First 1)
            if ($line) {
                $cols         = $line -split ','
                $totalVramMiB = [math]::Round([long]$cols[1].Trim() / 1MB)
                $usedVramMiB  = [math]::Round([long]$cols[2].Trim() / 1MB)
                $gpuName      = "AMD GPU"
            }
        } catch { Write-Warn "rocm-smi query failed: $_" }
    }
}

# ── Quantization menu ────────────────────────────────────────────────────────
# Shown whenever the model does not fit in free VRAM. The user picks a quant
# level and the script immediately runs `ollama pull <model>:<tag>` for them.
# ─────────────────────────────────────────────────────────────────────────────
$quantMenu = [ordered]@{
    "1" = @{ tag = "q8_0";   label = "Q8_0    8-bit,  ~100% quality, ~12% smaller  (best for large VRAM)" }
    "2" = @{ tag = "q6_K";   label = "Q6_K    6-bit,  ~99%  quality,  ~35% smaller" }
    "3" = @{ tag = "q5_K_M"; label = "Q5_K_M  5-bit,  ~97%  quality,  ~41% smaller  (recommended)" }
    "4" = @{ tag = "q4_K_M"; label = "Q4_K_M  4-bit,  ~95%  quality,  ~50% smaller  (most popular)" }
    "5" = @{ tag = "q3_K_M"; label = "Q3_K_M  3-bit,  ~91%  quality,  ~62% smaller" }
    "6" = @{ tag = "q2_K";   label = "Q2_K    2-bit,  ~85%  quality,  ~75% smaller  (last resort)" }
    "0" = @{ tag = $null;    label = "Skip    do not pull a quantized variant now" }
}

function Invoke-QuantMenu([string]$baseName) {
    Write-Host ""
    Write-Warn "Quantization options for '$baseName':"
    foreach ($key in $quantMenu.Keys) {
        Write-Host ("    [{0}]  {1}" -f $key, $quantMenu[$key].label) -ForegroundColor DarkYellow
    }
    Write-Host ""
    $qChoice = $null
    do { $qChoice = Read-Host "  Pick a quantization level (0 to skip)" }
    while (-not $quantMenu.Contains($qChoice))

    if ($quantMenu[$qChoice].tag) {
        $pullTarget = "${baseName}:$($quantMenu[$qChoice].tag)"
        Write-Info "Pulling $pullTarget — this may take a few minutes..."
        & ollama pull $pullTarget
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "Pulled $pullTarget successfully."
            return $pullTarget
        } else {
            Write-Warn "Pull failed (exit $LASTEXITCODE). The original model was not changed."
        }
    } else {
        Write-Info "Skipped quantization pull."
    }
    return $null
}

if ($totalVramMiB) {
    $freeMiB  = $totalVramMiB - $usedVramMiB
    $freeGiB  = [math]::Round($freeMiB        / 1024, 1)
    $totalGiB = [math]::Round($totalVramMiB   / 1024, 1)
    $usedGiB  = [math]::Round($usedVramMiB    / 1024, 1)

    Write-Info "GPU : $gpuName"
    Write-Info "VRAM: ${totalGiB} GiB total  |  ${usedGiB} GiB used  |  ${freeGiB} GiB free"

    $highWaterMark = [math]::Round($totalVramMiB * 0.35)
    if ($usedVramMiB -gt $highWaterMark -and -not $selectedModel) {
        Write-Warn "Another process is using more than 35 % of VRAM ($usedGiB / $totalGiB GiB)."
        Write-Warn "Close GPU-heavy apps (games, other AI tools) before loading a model."
    }

    if ($selectedModel) {
        $modelSize = ($modelObjs | Where-Object { $_.name -eq $selectedModel } | Select-Object -First 1).size
        $modelMiB  = ConvertTo-MiB $modelSize

        if ($modelMiB) {
            $needed  = $modelMiB + [math]::Round($modelMiB * 0.10)   # +10 % KV-cache overhead
            $baseName = ($selectedModel -replace ':.*$', '')

            Write-Info ("Model '{0}' requires ~{1} GiB (with 10 % overhead)." -f $selectedModel, [math]::Round($needed / 1024, 1))

            if ($needed -le $freeMiB) {
                Write-Ok "Model fits comfortably in free VRAM."
            } elseif ($needed -le $totalVramMiB) {
                Write-Warn "Model needs $([math]::Round($needed/1024,1)) GiB but only $freeGiB GiB is free."
                if ($usedVramMiB -gt $highWaterMark) {
                    Write-Warn "A large process is hogging VRAM. Free it first, or choose a quantized variant:"
                } else {
                    Write-Warn "Freeing currently-used VRAM may be enough, or pick a smaller quantized variant:"
                }
                $newModel = Invoke-QuantMenu $baseName
                if ($newModel) { $selectedModel = $newModel }
            } else {
                Write-Fail "Model ($([math]::Round($modelMiB/1024,1)) GiB) exceeds total VRAM ($totalGiB GiB)."
                Write-Warn "You must use a quantized (smaller) variant to run this model on your GPU:"
                $newModel = Invoke-QuantMenu $baseName
                if ($newModel) { $selectedModel = $newModel }
            }
        } else {
            Write-Info "Could not parse model size — skipping VRAM fit check."
        }
    }
} else {
    Write-Warn "No GPU detected via nvidia-smi / rocm-smi. Ollama will run on CPU."
    Write-Info "(Install CUDA / ROCm drivers and add nvidia-smi / rocm-smi to PATH for GPU checks.)"
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4 — Export OLLAMA_HOST so every extension finds the server automatically
# ─────────────────────────────────────────────────────────────────────────────
Write-Header "STEP 4 of 5 — Environment Variables"

$env:OLLAMA_HOST = $OllamaHost
[System.Environment]::SetEnvironmentVariable("OLLAMA_HOST", $OllamaHost, "User")
Write-Ok "OLLAMA_HOST = '$OllamaHost'  (set for this process AND your Windows user profile)."
Write-Info "Any process started after this point — including VS Code — will inherit OLLAMA_HOST."

if ($selectedModel) {
    $env:OLLAMA_MODEL = $selectedModel
    [System.Environment]::SetEnvironmentVariable("OLLAMA_MODEL", $selectedModel, "User")
    Write-Ok "OLLAMA_MODEL = '$selectedModel'."
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 5 — Open VS Code and connect Ollama as a local AI agent
# ─────────────────────────────────────────────────────────────────────────────
#
#  What this step does and WHY:
#
#  VS Code extensions like "Continue" (continue.dev) and the GitHub Copilot
#  "local model" feature discover an Ollama backend by reading the OLLAMA_HOST
#  environment variable that was just set in step 4.
#
#  Because we launch VS Code from THIS script (which already has OLLAMA_HOST in
#  its process environment), the new VS Code window inherits the variable
#  immediately — no system restart needed.
#
#  Once VS Code is open you can use Ollama as an agent in two ways:
#
#    A) GitHub Copilot Chat (built-in, VS Code ≥ 1.91)
#       → Open the Chat panel  (Ctrl+Alt+I)
#       → Click the model picker at the bottom of the input box
#       → Select "Use Local AI" → pick your Ollama model from the list
#       → Copilot will now route requests to http://OLLAMA_HOST  (no key needed)
#
#    B) Continue extension  (recommended for full agent/chat experience)
#       → Install "Continue" from the marketplace if not already installed
#       → Continue auto-reads OLLAMA_HOST on startup
#       → Open the Continue sidebar  (Ctrl+L)  and start chatting
#
#  The script also writes a  .vscode/settings.json  entry so the Continue
#  extension pre-selects the chosen model without any manual configuration.
# ─────────────────────────────────────────────────────────────────────────────
Write-Header "STEP 5 of 5 — Open VS Code + Register Ollama as Agent"

# Write .vscode/settings.json so Continue (and compatible extensions) pick up
# the chosen model automatically when the workspace opens.
if ($selectedModel) {
    $vscodeDir = Join-Path $WorkDir ".vscode"
    $settingsFile = Join-Path $vscodeDir "settings.json"

    if (-not (Test-Path $vscodeDir)) { New-Item -ItemType Directory -Path $vscodeDir | Out-Null }

    $existing = if (Test-Path $settingsFile) {
        Get-Content $settingsFile -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
    } else { [PSCustomObject]@{} }

    # Add / update the Continue and Copilot local-model keys
    $existing | Add-Member -Force -NotePropertyName "continue.models" -NotePropertyValue @(
        [PSCustomObject]@{
            title    = $selectedModel
            provider = "ollama"
            model    = $selectedModel
            apiBase  = "http://$OllamaHost"
        }
    )
    $existing | Add-Member -Force -NotePropertyName "github.copilot.advanced" -NotePropertyValue (
        [PSCustomObject]@{ localModels = @([PSCustomObject]@{ name = $selectedModel; endpoint = "http://$OllamaHost" }) }
    )

    $existing | ConvertTo-Json -Depth 10 | Set-Content -Path $settingsFile -Encoding UTF8
    Write-Ok "Wrote $settingsFile with Ollama model '$selectedModel'."
}

$codeCli = Get-Command "code" -ErrorAction SilentlyContinue
if (-not $codeCli) {
    Write-Warn "'code' command not found on PATH."
    Write-Info "Enable it in VS Code: Help → Shell Command → Install 'code' command in PATH."
    Write-Info "Then re-run this script to open VS Code automatically."
} else {
    Write-Info "Opening VS Code in: $WorkDir"
    & code $WorkDir
    Write-Ok "VS Code is opening."
    Write-Host ""
    Write-Info "── How to use Ollama as an AI agent inside VS Code ──────────────────────────"
    Write-Host "  Option A  GitHub Copilot Chat (built-in, no extra install)" -ForegroundColor DarkCyan
    Write-Host "            1. Open Chat:         Ctrl+Alt+I" -ForegroundColor Gray
    Write-Host "            2. Click model picker at the bottom of the chat input box" -ForegroundColor Gray
    Write-Host "            3. Choose 'Use Local AI'  →  select your Ollama model" -ForegroundColor Gray
    Write-Host "            4. Chat normally — requests are sent to http://$OllamaHost" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Option B  Continue extension  (richer agent / inline-edit experience)" -ForegroundColor DarkCyan
    Write-Host "            1. Install: Ctrl+Shift+X  →  search 'Continue'" -ForegroundColor Gray
    Write-Host "            2. Continue reads OLLAMA_HOST automatically on startup" -ForegroundColor Gray
    Write-Host "            3. Open sidebar: Ctrl+L  →  start chatting or use @codebase" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Both options use the model and host configured in this session:" -ForegroundColor DarkCyan
    Write-Host "    OLLAMA_HOST  = http://$OllamaHost" -ForegroundColor Gray
    if ($selectedModel) {
        Write-Host "    OLLAMA_MODEL = $selectedModel" -ForegroundColor Gray
    }
    Write-Info "─────────────────────────────────────────────────────────────────────────────"
}

# ─────────────────────────────────────────────────────────────────────────────
# SUMMARY
# ─────────────────────────────────────────────────────────────────────────────
Write-Header "Summary"
Write-Ok "Ollama API  : http://$OllamaHost"
if ($selectedModel) { Write-Ok "Active model: $selectedModel" }
Write-Info "Useful commands:"
Write-Host "    ollama list                    # show all local models" -ForegroundColor Gray
Write-Host "    ollama pull <model>            # download a new model" -ForegroundColor Gray
Write-Host "    ollama pull <model>:q4_K_M     # download a 4-bit quantized variant" -ForegroundColor Gray
Write-Host "    ollama rm <model>              # delete a local model to free VRAM" -ForegroundColor Gray
Write-Host "    ollama ps                      # show which models are currently loaded" -ForegroundColor Gray
Write-Host ""
