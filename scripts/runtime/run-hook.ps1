param([Parameter(Mandatory=$true)][ValidateSet('red-zone','retro','inventory')][string]$Hook)
$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$rawInput = [Console]::In.ReadToEnd()
try {
    # Resolve from this file, never from the tool's requested workdir.
    $adapterPath = Join-Path $PSScriptRoot 'codex_hook.py'
    if ($env:SYSADMIN_PYTHON -and (Test-Path -LiteralPath $env:SYSADMIN_PYTHON -PathType Leaf)) {
        $pythonPath = $env:SYSADMIN_PYTHON
    } else {
        # Первый найденный python3 может оказаться заглушкой Microsoft Store: берём первого
        # кандидата, который реально запускается и даёт 3.11+.
        $pythonPath = $null
        foreach ($cand in (Get-Command python3,python,py -All -ErrorAction SilentlyContinue)) {
            try {
                & $cand.Source -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>$null | Out-Null
                if ($LASTEXITCODE -eq 0) { $pythonPath = $cand.Source; break }
            } catch { }
        }
        if (-not $pythonPath) { throw 'Нужен работающий Python 3.11+ в PATH.' }
    }
    $env:PYTHONIOENCODING = 'utf-8'
    $rawInput | & $pythonPath $adapterPath $Hook
    if ($LASTEXITCODE -ne 0) { throw "Python-переходник завершился с кодом $LASTEXITCODE." }
} catch {
    $reason = "Переходник Sysadmin/Codex не запустился: $($_.Exception.Message)"
    if ($Hook -eq 'inventory') {
        @{systemMessage=$reason} | ConvertTo-Json -Compress
    } else {
        @{hookSpecificOutput=@{hookEventName='PreToolUse';permissionDecision='deny';permissionDecisionReason=$reason}} |
            ConvertTo-Json -Depth 4 -Compress
    }
    exit 0
}
