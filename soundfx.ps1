# soundfx.ps1 — Sound Effect Generator CLI (Windows / Stream Deck)
# Usage:
#   .\soundfx.ps1 script.txt              # Analyse script, print prompts
#   .\soundfx.ps1 script.txt --generate   # Analyse + generate sound effects
#   .\soundfx.ps1 --test                  # Test API connections

[CmdletBinding()]
param (
    [Parameter(Position = 0)]
    [string]$ScriptFile,

    [switch]$Generate,

    [int]$Variants = 0,

    [ValidateSet('elevenlabs', 'fal')]
    [string]$Backend = '',

    [switch]$Test,

    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$EnvFile   = Join-Path $ScriptDir '.env'

# ─── Load .env ────────────────────────────────────────────────────────────────
function Load-EnvFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        Write-Warning "No .env file found at $Path"
        Write-Warning "Copy .env.example to .env and fill in your API keys."
        return
    }
    Get-Content $Path | ForEach-Object {
        # Skip blank lines and comments
        if ($_ -match '^([A-Z_]+)=(.*)$') {
            $key   = $Matches[1]
            $value = $Matches[2] -replace '\s*#.*$', ''  # strip inline comments
            [System.Environment]::SetEnvironmentVariable($key, $value, 'Process')
        }
    }
}

Load-EnvFile $EnvFile

# Read env vars (after loading .env)
$ElevenLabsKey = [System.Environment]::GetEnvironmentVariable('ELEVENLABS_API_KEY') ?? ''
$FalKey        = [System.Environment]::GetEnvironmentVariable('FAL_API_KEY')         ?? ''
$XaiKey        = [System.Environment]::GetEnvironmentVariable('XAI_API_KEY')         ?? ''
$EnvBackend    = [System.Environment]::GetEnvironmentVariable('BACKEND')             ?? 'elevenlabs'
$EnvVariants   = [System.Environment]::GetEnvironmentVariable('VARIANTS')            ?? '3'

# CLI args override .env
if ($Backend -eq '') { $Backend = $EnvBackend }
if ($Variants -eq 0) { $Variants = [int]$EnvVariants }

$OutputDir = Join-Path $ScriptDir 'generated_sounds'
if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir | Out-Null }

# ─── Helpers ──────────────────────────────────────────────────────────────────
function Print-Usage {
    Write-Host @"
Usage:
  .\soundfx.ps1 <script_file> [-Generate] [-Variants N] [-Backend elevenlabs|fal]
  .\soundfx.ps1 -Test

Options:
  -Generate         Generate audio files for each suggested prompt
  -Variants N       Number of audio variants per prompt (default: $Variants)
  -Backend NAME     Override backend: elevenlabs or fal (default: $Backend)
  -Test             Test API connections and exit

Environment (.env):
  ELEVENLABS_API_KEY   ElevenLabs API key
  FAL_API_KEY          fal.ai API key
  XAI_API_KEY          Grok/xAI API key
  BACKEND              elevenlabs or fal
  VARIANTS             Number of variants per prompt
"@
}

function Invoke-ApiRequest {
    param(
        [string]$Uri,
        [string]$Method = 'GET',
        [hashtable]$Headers = @{},
        [object]$Body = $null,
        [string]$OutFile = $null
    )
    $params = @{
        Uri     = $Uri
        Method  = $Method
        Headers = $Headers
    }
    if ($Body) {
        $params.Body        = ($Body | ConvertTo-Json -Depth 10 -Compress)
        $params.ContentType = 'application/json'
    }
    if ($OutFile) { $params.OutFile = $OutFile }

    try {
        if ($OutFile) {
            Invoke-WebRequest @params -UseBasicParsing | Out-Null
            return $null
        }
        return Invoke-RestMethod @params -UseBasicParsing
    }
    catch [System.Net.WebException] {
        $statusCode = [int]$_.Exception.Response.StatusCode
        throw "HTTP $statusCode : $($_.Exception.Message)"
    }
}

# ─── Connection Tests ─────────────────────────────────────────────────────────
function Test-ElevenLabsConnection {
    if (-not $ElevenLabsKey) { Write-Host "❌ ElevenLabs: No API key set"; return $false }
    try {
        $resp = Invoke-ApiRequest -Uri 'https://api.elevenlabs.io/v1/user' `
            -Headers @{ 'xi-api-key' = $ElevenLabsKey }
        $tier = $resp.subscription.tier ?? 'connected'
        Write-Host "✅ ElevenLabs: Connected ($tier)"
        return $true
    }
    catch {
        Write-Host "❌ ElevenLabs: $_"
        return $false
    }
}

function Test-FalConnection {
    if (-not $FalKey) { Write-Host "❌ fal.ai: No API key set"; return $false }
    try {
        $resp = Invoke-ApiRequest -Uri 'https://fal.run/fal-ai/stable-audio' `
            -Method 'POST' `
            -Headers @{ 'Authorization' = "Key $FalKey" } `
            -Body @{ prompt = 'test'; seconds_total = 1 }
        Write-Host "✅ fal.ai: Connected"
        return $true
    }
    catch {
        $msg = "$_"
        if ($msg -match 'HTTP 401|HTTP 403') {
            Write-Host "❌ fal.ai: Auth failed — $_"
            return $false
        }
        # Other errors (4xx) still mean auth passed
        Write-Host "✅ fal.ai: Connected (auth ok — $_)"
        return $true
    }
}

function Test-XaiConnection {
    if (-not $XaiKey) { Write-Host "❌ Grok/xAI: No API key set"; return $false }
    try {
        $resp = Invoke-ApiRequest -Uri 'https://api.x.ai/v1/models' `
            -Headers @{ 'Authorization' = "Bearer $XaiKey" }
        $models = ($resp.data | Select-Object -First 3 | ForEach-Object { $_.id }) -join ', '
        Write-Host "✅ Grok/xAI: Connected ($models)"
        return $true
    }
    catch {
        Write-Host "❌ Grok/xAI: $_"
        return $false
    }
}

function Run-ConnectionTests {
    Write-Host "🔌 Testing API connections…`n"
    Test-ElevenLabsConnection | Out-Null
    Test-FalConnection        | Out-Null
    Test-XaiConnection        | Out-Null
    Write-Host ""
}

# ─── Grok Analysis ────────────────────────────────────────────────────────────
function Invoke-ScriptAnalysis {
    param([string]$ScriptContent)

    if (-not $XaiKey) {
        Write-Error "XAI_API_KEY is not set. Cannot analyse script."
        exit 1
    }

    Write-Host "🔍 Analysing script with Grok…"

    $body = @{
        model       = 'grok-beta'
        temperature = 0.3
        messages    = @(
            @{
                role    = 'system'
                content = 'You are a professional sound designer for video production. Analyse the provided video script and return a JSON array of sound effect suggestions. Each suggestion must be an object with: "timestamp" (string, e.g. "0:05"), "prompt" (concise text-to-audio description), "reason" (why this sound fits). Return ONLY valid JSON, no markdown, no extra text.'
            },
            @{
                role    = 'user'
                content = "Analyse this video script and suggest sound effects:`n`n$ScriptContent"
            }
        )
    }

    Write-Host "🐛 [DEBUG] Sending analysis request to https://api.x.ai/v1/chat/completions"
    Write-Host "🐛 [DEBUG] Payload: $($body | ConvertTo-Json -Depth 10 -Compress)"

    $resp = Invoke-ApiRequest -Uri 'https://api.x.ai/v1/chat/completions' `
        -Method 'POST' `
        -Headers @{ 'Authorization' = "Bearer $XaiKey" } `
        -Body $body

    $content = $resp.choices[0].message.content
    if (-not $content) { throw "Empty response from Grok" }

    # Parse JSON (extract array if model added extra text)
    try {
        return $content | ConvertFrom-Json
    }
    catch {
        $m = [regex]::Match($content, '\[[\s\S]*\]')
        if ($m.Success) { return $m.Value | ConvertFrom-Json }
        throw "Could not parse JSON from Grok response"
    }
}

# ─── Sound Generation ─────────────────────────────────────────────────────────
function Generate-ElevenLabs {
    param([string]$Prompt, [string]$OutFile)
    $body = @{ text = $Prompt; duration_seconds = $null; prompt_influence = 0.3 }
    Write-Host "  🐛 [DEBUG] Sending prompt to ElevenLabs: $Prompt"
    Write-Host "  🐛 [DEBUG] Payload: $($body | ConvertTo-Json -Depth 10 -Compress)"
    try {
        $params = @{
            Uri         = 'https://api.elevenlabs.io/v1/sound-generation'
            Method      = 'POST'
            Headers     = @{ 'xi-api-key' = $ElevenLabsKey }
            Body        = ($body | ConvertTo-Json -Depth 5 -Compress)
            ContentType = 'application/json'
            OutFile     = $OutFile
        }
        Invoke-WebRequest @params -UseBasicParsing | Out-Null
        Write-Host "  ✅ Saved: $OutFile"
    }
    catch {
        Write-Host "  ❌ ElevenLabs error: $_"
        if (Test-Path $OutFile) { Remove-Item $OutFile }
    }
}

function Generate-Fal {
    param([string]$Prompt, [string]$OutFile)
    try {
        $body = @{ prompt = $Prompt; seconds_total = 10; steps = 100 }
        Write-Host "  🐛 [DEBUG] Sending prompt to fal.ai: $Prompt"
        Write-Host "  🐛 [DEBUG] Payload: $($body | ConvertTo-Json -Depth 10 -Compress)"
        $resp = Invoke-ApiRequest -Uri 'https://fal.run/fal-ai/stable-audio' `
            -Method 'POST' `
            -Headers @{ 'Authorization' = "Key $FalKey" } `
            -Body $body

        $audioUrl = $resp.audio_file.url ?? $resp.audio.url ?? $resp.outputs[0].url
        if (-not $audioUrl) { throw "No audio URL in response" }

        Invoke-WebRequest -Uri $audioUrl -OutFile $OutFile -UseBasicParsing | Out-Null
        Write-Host "  ✅ Saved: $OutFile"
    }
    catch {
        Write-Host "  ❌ fal.ai error: $_"
    }
}

# ─── Main ─────────────────────────────────────────────────────────────────────
if ($Help) { Print-Usage; exit 0 }

if ($Test) {
    Run-ConnectionTests
    exit 0
}

if (-not $ScriptFile) {
    Print-Usage
    exit 1
}

if (-not (Test-Path $ScriptFile)) {
    Write-Error "Script file not found: $ScriptFile"
    exit 1
}

$ScriptContent = Get-Content -Path $ScriptFile -Raw
$Suggestions   = Invoke-ScriptAnalysis -ScriptContent $ScriptContent

Write-Host ""
Write-Host "📋 Suggested Sound Effects:"
Write-Host "─────────────────────────────────────────"

foreach ($s in $Suggestions) {
    Write-Host "[$($s.timestamp)] $($s.prompt)  — $($s.reason)"
}

Write-Host "─────────────────────────────────────────"
Write-Host "Total: $($Suggestions.Count) prompts"

if ($Generate) {
    Write-Host ""
    Write-Host "🎵 Generating sound effects (backend: $Backend, variants: $Variants)…"
    Write-Host ""

    $Timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'

    foreach ($s in $Suggestions) {
        $Prompt      = $s.prompt
        $Ts          = $s.timestamp
        $words      = ($Prompt -split '\s+' | Where-Object { $_ -ne '' } | Select-Object -First 3)
        $SafePrompt = ($words | ForEach-Object { ($_ -replace '[^a-zA-Z0-9]', '').ToLower() } | Where-Object { $_ -ne '' }) -join '_'

        Write-Host "🔊 [$Ts] $Prompt"

        for ($v = 1; $v -le $Variants; $v++) {
            $OutFile = Join-Path $OutputDir "${SafePrompt}_v${v}_${Timestamp}.mp3"
            if ($Backend -eq 'fal') {
                Generate-Fal -Prompt $Prompt -OutFile $OutFile
            }
            else {
                Generate-ElevenLabs -Prompt $Prompt -OutFile $OutFile
            }
        }
        Write-Host ""
    }

    Write-Host "✅ Done! Files saved to: $OutputDir"
}
