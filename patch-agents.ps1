<#
.SYNOPSIS
    Pick one Ollama model and register it as a VS Code agent.
#>

[CmdletBinding()]
param(
    [string] $WorkDir    = (Get-Location).Path,
    [string] $OllamaHost = "127.0.0.1:11434"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Ok   ([string]$t) { Write-Host ("  [OK]  " + $t) -ForegroundColor Green  }
function Write-Warn ([string]$t) { Write-Host ("  [!!]  " + $t) -ForegroundColor Yellow }
function Write-Info ([string]$t) { Write-Host ("  [..]  " + $t) -ForegroundColor White  }
function Write-Fail ([string]$t) { Write-Host ("  [XX]  " + $t) -ForegroundColor Red    }

$HostUrl = "http://$OllamaHost"
Write-Host "
=== Ollama Local AI for VS Code ===" -ForegroundColor Cyan

function Ensure-OllamaInstalled {
    if (Get-Command ollama -ErrorAction SilentlyContinue) {
        $path = (Get-Command ollama).Source
        Write-Ok "Ollama CLI found: $path"
        return
    }
    Write-Warn "Ollama CLI was not found."
    
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        $ans = Read-Host "  Install Ollama with winget now? [Y/n]"
        if ([string]::IsNullOrWhiteSpace($ans) -or $ans -match '^[Yy]') {
            winget install --id Ollama.Ollama -e
            Write-Ok "Ollama installed."
            return
        }
    }

    Start-Process "https://ollama.com/download" -ErrorAction SilentlyContinue
    Write-Fail "Install Ollama from https://ollama.com/download, then run this script again."
    exit 1
}

function Wait-ForOllama {
    for ($i=0; $i -lt 30; $i++) {
        try {
            $resp = Invoke-WebRequest -Uri $HostUrl -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
            Write-Ok "Ollama API is reachable at $HostUrl"
            return $true
        } catch {
            Start-Sleep -Seconds 1
        }
    }
    return $false
}

function Start-Ollama {
    if (Wait-ForOllama) { return }
    Write-Info "Starting Ollama server..."
    Start-Process -WindowStyle Hidden -FilePath "ollama" -ArgumentList "serve"
    if (-not (Wait-ForOllama)) {
        Write-Fail "Ollama did not become reachable at $HostUrl."
        exit 1
    }
}

function Pull-FirstModelIfNeeded {
    $models = Get-OllamaModels
    if ($models.Count -gt 0) { return }

    Write-Warn "No Ollama models are installed yet."
    $recommendations = @()
    $modelsFile = Join-Path $PSScriptRoot "models.txt"
    if (Test-Path $modelsFile) {
        foreach ($line in Get-Content $modelsFile) {
            $cleaned = $line -split '#' | Select-Object -First 1
            $cleaned = $cleaned.Trim()
            if ($cleaned) { $recommendations += $cleaned }
        }
    }
    if ($recommendations.Count -eq 0) {
        $recommendations = @("llama3.1:8b", "qwen2.5-coder:7b", "deepseek-coder:6.7b")
    }

    Write-Host ""
    Write-Host "  Recommended models:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $recommendations.Count; $i++) {
        Write-Host ("    [{0,2}]  {1}" -f ($i + 1), $recommendations[$i])
    }
    Write-Host ""

    $pullModel = $null
    while (-not $pullModel) {
        $ans = Read-Host "  Enter model number to pull"
        if ($ans -match '^\d+$') {
            $idx = [int]$ans - 1
            if ($idx -ge 0 -and $idx -lt $recommendations.Count) {
                $pullModel = $recommendations[$idx]
            }
        }
        if (-not $pullModel) { Write-Warn "Please enter a number between 1 and $($recommendations.Count)." }
    }

    Write-Info "Pulling $pullModel. This can take a while..."
    ollama pull $pullModel
}

function Get-OllamaModels {
    $raw = ollama list 2>&1
    $models = @()
    foreach ($line in $raw) {
        if ($line -match 'NAME' -or [string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line -split '\s+'
        if ($parts.Count -ge 1 -and $parts[0]) { $models += $parts[0] }
    }
    return @($models)
}

function Select-Model {
    $models = Get-OllamaModels
    Write-Host ""
    Write-Host "  Installed Ollama models:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $models.Count; $i++) {
        Write-Host ("    [{0,2}]  {1}" -f ($i + 1), $models[$i])
    }
    Write-Host ""

    $Global:SelectedModel = $null
    while (-not $Global:SelectedModel) {
        $ans = Read-Host "  Enter the ONE model number to use in VS Code"
        if ($ans -match '^\d+$') {
            $idx = [int]$ans - 1
            if ($idx -ge 0 -and $idx -lt $models.Count) {
                $Global:SelectedModel = $models[$idx]
            }
        }
        if (-not $Global:SelectedModel) { Write-Warn "Please enter a number between 1 and $($models.Count)." }
    }
    Write-Ok "Selected model: $Global:SelectedModel"
}

function Persist-Environment {
    $env:OLLAMA_HOST = $OllamaHost
    $env:OLLAMA_MODEL = $Global:SelectedModel
    [Environment]::SetEnvironmentVariable("OLLAMA_HOST", $OllamaHost, "User")
    [Environment]::SetEnvironmentVariable("OLLAMA_MODEL", $Global:SelectedModel, "User")
    Write-Ok "Saved OLLAMA_HOST and OLLAMA_MODEL to Windows User Profile"
}

function Write-VsCodeSettings {
    $vscodeDir = Join-Path $WorkDir ".vscode"
    $settingsFile = Join-Path $vscodeDir "settings.json"
    if (-not (Test-Path $vscodeDir)) { New-Item -ItemType Directory -Path $vscodeDir | Out-Null }

    $data = [PSCustomObject]@{}
    if (Test-Path $settingsFile) {
        try { $data = Get-Content $settingsFile -Raw | ConvertFrom-Json } catch {}
    }

    if ($data.PSObject.Properties.Match('github.copilot.advanced').Count -gt 0) {
        $data.PSObject.Properties.Remove("github.copilot.advanced")
    }

    $continueModel = @(
        [PSCustomObject]@{
            title    = $Global:SelectedModel
            provider = "ollama"
            model    = $Global:SelectedModel
            apiBase  = $HostUrl
        }
    )

    $data | Add-Member -Force -NotePropertyName "continue.models" -NotePropertyValue $continueModel
    $data | Add-Member -Force -NotePropertyName "continue.defaultModel" -NotePropertyValue $Global:SelectedModel

    $data | ConvertTo-Json -Depth 10 | Set-Content -Path $settingsFile -Encoding UTF8
    Write-Ok "Wrote $settingsFile for Continue ($Global:SelectedModel)"
}

function Install-ContinueIfPossible {
    if (Get-Command code -ErrorAction SilentlyContinue) {
        Write-Info "Installing/updating Continue extension in VS Code..."
        $proc = Start-Process -FilePath "code" -ArgumentList "--install-extension","Continue.continue","--force" -Wait -PassThru -NoNewWindow
        if ($proc.ExitCode -eq 0) { return }
    }
    Write-Warn "VS Code 'code' CLI not found or failed; install Continue manually from Extensions."
}

function Open-VsCode {
    if (Get-Command code -ErrorAction SilentlyContinue) {
        Write-Info "Opening VS Code in $WorkDir"
        $env:OLLAMA_HOST = $OllamaHost
        $env:OLLAMA_MODEL = $Global:SelectedModel
        Start-Process -FilePath "code" -ArgumentList ""$WorkDir"" -NoNewWindow
    } else {
        Write-Warn "VS Code was configured, but I could not open it automatically."
    }
}

Ensure-OllamaInstalled
Start-Ollama
Pull-FirstModelIfNeeded
Select-Model
Persist-Environment
Write-VsCodeSettings
Install-ContinueIfPossible
Open-VsCode

Write-Host "
=== Done ===" -ForegroundColor Cyan
Write-Host "  Active local model:  $Global:SelectedModel" -ForegroundColor Green
Write-Host "  Ollama API:          $HostUrl" -ForegroundColor Green
Write-Host "
  Use it now:" -ForegroundColor Cyan
Write-Host "  1. In VS Code, open Continue from the sidebar." -ForegroundColor Gray
Write-Host "  2. Use $Global:SelectedModel with chat, @codebase, or edits." -ForegroundColor Gray
Write-Host "
  About GitHub Copilot Chat:" -ForegroundColor Cyan
Write-Host "  This script sets OLLAMA_HOST correctly for Copilot local-model detection." -ForegroundColor Gray
Write-Host "  If Copilot Chat is unavailable, VS Code cannot show local models inside Copilot." -ForegroundColor Gray
Write-Host "  Continue is the no-Copilot-access local AI route and has been configured.
" -ForegroundColor Gray
