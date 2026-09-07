[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "Starting V4 updater fixture server listener contract tests..."

$coreScriptPath = Join-Path $PSScriptRoot 'ci_tauri_update_e2e_core.ps1'

# Test 1: Static guard - ensure ci_tauri_update_e2e_core.ps1 does not call .Close() on listener
Write-Host "Test 1: Static guard against unsupported TcpListener.Close()..."
if (-not (Test-Path -LiteralPath $coreScriptPath)) {
    throw "Could not locate ci_tauri_update_e2e_core.ps1 at $coreScriptPath"
}
$coreContent = Get-Content -LiteralPath $coreScriptPath -Raw
if ($coreContent -match '(?i)\$listener\s*\.\s*Close\s*\(') {
    throw "FAILED: ci_tauri_update_e2e_core.ps1 still contains unsupported `$listener.Close() call"
}
Write-Host "Test 1: PASS"

# Test 2: Runtime platform contract - verify [System.Net.Sockets.TcpListener] does not expose Close()
Write-Host "Test 2: Platform contract on System.Net.Sockets.TcpListener..."
$listenerType = [System.Net.Sockets.TcpListener]
$closeMethod = $listenerType.GetMethod("Close", [System.Reflection.BindingFlags]"Public,Instance")
if ($null -ne $closeMethod) {
    throw "FAILED: System.Net.Sockets.TcpListener unexpectedly exposes a public instance Close() method"
}
Write-Host "Test 2: PASS"

# Test 3: Bounded fixture server background job with Stop() completes cleanly without Receive-Job errors
Write-Host "Test 3: Bounded fixture server lifecycle with Stop() cleanup..."
$tempDir = Join-Path ([IO.Path]::GetTempPath()) ("sky-v4-listener-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

$stopPath = Join-Path $tempDir "stop.signal"
$manifestPath = Join-Path $tempDir "manifest.json"
Set-Content -LiteralPath $manifestPath -Value '{"version":"4.0.0-test"}' -Encoding utf8

$testPort = 39182
$serverJob = $null
try {
    $serverJob = Start-Job -ScriptBlock {
        param($Port, $ManifestPath, $StopPath)
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Parse('127.0.0.1'), $Port)
        $listener.Start()
        try {
            $acceptTask = $listener.AcceptTcpClientAsync()
            while (-not (Test-Path -LiteralPath $StopPath)) {
                if (-not $acceptTask.Wait(100)) { continue }
                $client = $acceptTask.Result
                $acceptTask = $listener.AcceptTcpClientAsync()
                $stream = $null
                try {
                    $stream = $client.GetStream()
                    $requestBytes = [byte[]]::new(4096)
                    $read = $stream.Read($requestBytes, 0, $requestBytes.Length)
                    $request = [Text.Encoding]::ASCII.GetString($requestBytes, 0, $read)
                    $path = ($request -split "`r?`n", 2)[0].Split(' ')[1].Split('?')[0]
                    if ($path -eq '/stable') {
                        $bytes = [IO.File]::ReadAllBytes($ManifestPath)
                        $status = '200 OK'
                    } else {
                        $bytes = [Text.Encoding]::UTF8.GetBytes('not found')
                        $status = '404 Not Found'
                    }
                    $header = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $status`r`nContent-Type: application/json`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`n`r`n")
                    $stream.Write($header, 0, $header.Length)
                    $stream.Write($bytes, 0, $bytes.Length)
                    $stream.Flush()
                } finally {
                    if ($null -ne $stream) { $stream.Close() }
                    $client.Close()
                }
            }
        } finally {
            $listener.Stop()
        }
    } -ArgumentList $testPort, $manifestPath, $stopPath

    # Wait for server to become ready
    $ready = $false
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $resp = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$testPort/stable" -TimeoutSec 2
            if ($resp.StatusCode -eq 200) {
                $ready = $true
                break
            }
        } catch { }
        Start-Sleep -Milliseconds 100
    }
    if (-not $ready) {
        throw "Test fixture server did not become ready within deadline"
    }

    # Signal server to stop
    New-Item -ItemType File -Path $stopPath -Force | Out-Null

    # Wait for background job to reach terminal state
    $jobFinished = Wait-Job -Job $serverJob -Timeout 10
    if ($null -eq $jobFinished -or $serverJob.State -ne 'Completed') {
        throw "Test fixture server job did not transition to Completed (state: $($serverJob.State))"
    }

    # Receive-Job must succeed with NO cleanup errors
    $output = Receive-Job -Job $serverJob -ErrorAction Stop
    Write-Host "Test 3: PASS (server job completed cleanly)"
} finally {
    if ($null -ne $serverJob) {
        Stop-Job -Job $serverJob -ErrorAction SilentlyContinue
        Remove-Job -Job $serverJob -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $tempDir) {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Test 4: Regression proof - verify that reintroducing .Close() on TcpListener fails closed
Write-Host "Test 4: Regression proof that TcpListener.Close() fails closed..."
$tempDir4 = Join-Path ([IO.Path]::GetTempPath()) ("sky-v4-listener-neg-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempDir4 -Force | Out-Null
$stopPath4 = Join-Path $tempDir4 "stop.signal"
$negPort = 39183
$negJob = $null
try {
    $negJob = Start-Job -ScriptBlock {
        param($Port, $StopPath)
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Parse('127.0.0.1'), $Port)
        $listener.Start()
        try {
            while (-not (Test-Path -LiteralPath $StopPath)) {
                Start-Sleep -Milliseconds 100
            }
        } finally {
            $listener.Stop()
            $listener.Close()
        }
    } -ArgumentList $negPort, $stopPath4

    Start-Sleep -Milliseconds 300
    New-Item -ItemType File -Path $stopPath4 -Force | Out-Null
    Wait-Job -Job $negJob -Timeout 10 | Out-Null

    $negFailed = $false
    try {
        Receive-Job -Job $negJob -ErrorAction Stop | Out-Null
    } catch {
        if ($_.Exception.Message -match "does not contain a method named 'Close'") {
            $negFailed = $true
        } else {
            throw "FAILED: Expected missing 'Close' method error, got: $($_.Exception.Message)"
        }
    }
    if (-not $negFailed) {
        throw "FAILED: TcpListener.Close() unexpectedly succeeded without error"
    }
    Write-Host "Test 4: PASS (reintroducing Close() confirmed to fail Receive-Job)"
} finally {
    if ($null -ne $negJob) {
        Stop-Job -Job $negJob -ErrorAction SilentlyContinue
        Remove-Job -Job $negJob -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $tempDir4) {
        Remove-Item -LiteralPath $tempDir4 -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "================================================================="
Write-Host " [PASS] All V4 updater fixture server listener tests passed"
Write-Host "================================================================="
