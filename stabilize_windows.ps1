#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Prepares Windows for repeatable WSL2 / Kubernetes benchmarks.
.DESCRIPTION
    Creates a temporary copy of the CURRENT Windows power scheme.
    On AC power: processor min 5%, max 100%, boost disabled by default,
    no automatic sleep or hibernation. Core parking and P/E-core scheduling
    are left unchanged. Optionally stops WSearch and SysMain.

    Restore returns to the previous scheme, removes the temporary scheme,
    and restarts only services that were originally running.

    The Windows power-mode overlay, registry, and service startup types
    are NOT modified. The original power scheme is NOT modified.

.EXAMPLE
    .\stabilize_windows.ps1
.EXAMPLE
    .\stabilize_windows.ps1 -KeepBoost
.EXAMPLE
    .\stabilize_windows.ps1 -SkipServices
.EXAMPLE
    .\stabilize_windows.ps1 -Status
.EXAMPLE
    .\stabilize_windows.ps1 -Restore
#>
[CmdletBinding(DefaultParameterSetName = 'Enable')]
param(
    [Parameter(ParameterSetName = 'Restore')]
    [switch]$Restore,

    [Parameter(ParameterSetName = 'Status')]
    [switch]$Status,

    [Parameter(ParameterSetName = 'Enable')]
    [switch]$KeepBoost,

    [Parameter(ParameterSetName = 'Enable')]
    [switch]$SkipServices
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$StateDir = Join-Path $env:LOCALAPPDATA 'ThesisBenchmark'
$StateFile = Join-Path $StateDir 'state.json'
$GuidPattern = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
$BackgroundServices = @('WSearch', 'SysMain')

function Invoke-PowerCfg {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $output = & powercfg.exe @Arguments
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "powercfg $($Arguments -join ' ') failed (exit code $exitCode)."
    }
    return ($output -join "`n")
}

function Get-ActivePowerScheme {
    $output = Invoke-PowerCfg -Arguments @('/getactivescheme')
    $match = [regex]::Match($output, $GuidPattern)
    if (-not $match.Success) {
        throw 'Could not find the active power scheme GUID.'
    }
    return $match.Value.ToLowerInvariant()
}

function Test-PowerSchemeExists {
    param([string]$Guid)
    $list = Invoke-PowerCfg -Arguments @('/list')
    return ($list -match [regex]::Escape($Guid))
}

function Save-BenchmarkState {
    param([Parameter(Mandatory = $true)]$State)

    if (-not (Test-Path -LiteralPath $StateDir)) {
        New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
    }

    $tmp = Join-Path $StateDir 'state.json.tmp'
    $State | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $StateFile -Force
}

function Read-BenchmarkState {
    if (-not (Test-Path -LiteralPath $StateFile)) {
        return $null
    }
    $state = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
    if (-not $state.PreviousScheme -or -not $state.BenchmarkScheme) {
        throw "Invalid benchmark state file: $StateFile"
    }
    return $state
}

function Restore-BenchmarkState {
    param([Parameter(Mandatory = $true)]$SavedState)

    $success = $true

    # Restore the original scheme BEFORE deleting the temporary one.
    try {
        $previous = [string]$SavedState.PreviousScheme
        if (-not (Test-PowerSchemeExists -Guid $previous)) {
            throw "Original scheme no longer exists: $previous"
        }
        if ((Get-ActivePowerScheme) -ne $previous) {
            Invoke-PowerCfg -Arguments @('/setactive', $previous) | Out-Null
        }
        Write-Host "Power scheme restored: $previous" -ForegroundColor Green
    }
    catch {
        Write-Warning "Failed to restore power scheme: $_"
        $success = $false
    }

    try {
        $benchmark = [string]$SavedState.BenchmarkScheme
        if (Test-PowerSchemeExists -Guid $benchmark) {
            if ((Get-ActivePowerScheme) -eq $benchmark) {
                throw 'Temporary power scheme is still active; cannot delete it.'
            }
            Invoke-PowerCfg -Arguments @('/delete', $benchmark) | Out-Null
            Write-Host 'Temporary benchmark power scheme deleted.' -ForegroundColor Green
        }
    }
    catch {
        Write-Warning "Failed to delete benchmark scheme: $_"
        $success = $false
    }

    foreach ($name in @($SavedState.ServicesToRestart)) {
        if (-not $name) { continue }
        try {
            $service = Get-Service -Name $name -ErrorAction Stop
            if ($service.Status -ne 'Running') {
                Start-Service -Name $name -ErrorAction Stop
                Write-Host "Service restarted: $name" -ForegroundColor Green
            }
        }
        catch {
            Write-Warning "Failed to restart service $name : $_"
            $success = $false
        }
    }

    if ($success) {
        Remove-Item -LiteralPath $StateFile -Force
        Write-Host 'Restore complete.' -ForegroundColor Green
    }
    else {
        Write-Warning "Partial restore. State kept at $StateFile. Fix the issue and run -Restore again."
    }
    return $success
}

function Show-CurrentLoad {
    try {
        $samples = @()
        for ($i = 0; $i -lt 5; $i++) {
            $counter = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop
            $samples += [double]$counter.PercentProcessorTime
            if ($i -lt 4) { Start-Sleep -Seconds 1 }
        }
        $average = [math]::Round(($samples | Measure-Object -Average).Average, 1)
        Write-Host "Windows total CPU usage (5 samples): $average %"
        if ($average -gt 10) {
            Write-Warning 'Background CPU activity is above 10%. Consider closing other programs.'
        }
    }
    catch {
        Write-Warning "CPU usage check unavailable: $_"
    }
}

try {
    if ($Status) {
        Write-Host "Active power scheme: $(Get-ActivePowerScheme)"
        $state = Read-BenchmarkState
        if ($null -eq $state) {
            Write-Host 'Benchmark mode: inactive (no state file).'
        }
        else {
            Write-Host 'Benchmark mode: state file present.'
            Write-Host "Started (UTC):       $($state.StartedUtc)"
            Write-Host "Previous scheme:     $($state.PreviousScheme)"
            Write-Host "Benchmark scheme:    $($state.BenchmarkScheme)"
            Write-Host "Boost enabled:       $($state.BoostEnabled)"
            Write-Host "Services to restart: $(@($state.ServicesToRestart) -join ', ')"
            Write-Host "State file:          $StateFile"
        }
        exit 0
    }

    if ($Restore) {
        $state = Read-BenchmarkState
        if ($null -eq $state) {
            Write-Warning "No state file found at $StateFile. Nothing to restore."
            exit 0
        }
        if (Restore-BenchmarkState -SavedState $state) { exit 0 }
        exit 1
    }

    if (Test-Path -LiteralPath $StateFile) {
        throw "Benchmark state already exists. Run -Status or -Restore first: $StateFile"
    }

    # Warn if on battery. No undocumented battery registry tweaks are used.
    try {
        $battery = @(Get-CimInstance -Namespace 'root/WMI' -ClassName 'BatteryStatus' -ErrorAction Stop)
        if (@($battery | Where-Object { -not $_.PowerOnline }).Count -gt 0) {
            Write-Warning 'AC power is disconnected. Plug in the charger before benchmarking.'
        }
    }
    catch {
        Write-Warning 'AC power status could not be verified.'
    }

    $previous = Get-ActivePowerScheme
    $benchmark = [guid]::NewGuid().ToString()
    $state = [ordered]@{
        Version           = 1
        StartedUtc        = (Get-Date).ToUniversalTime().ToString('o')
        PreviousScheme    = $previous
        BenchmarkScheme   = $benchmark
        BoostEnabled      = [bool]$KeepBoost
        MinimumCpuPercent = 5
        MaximumCpuPercent = 100
        CoreParking       = 'inherited'
        CpuScheduling     = 'inherited'
        ServicesToRestart = @()
    }

    # Create recovery state BEFORE making any system changes.
    Save-BenchmarkState -State $state

    try {
        # A known destination GUID allows recovery even after interruptions.
        Invoke-PowerCfg -Arguments @('/duplicatescheme', $previous, $benchmark) | Out-Null
        Invoke-PowerCfg -Arguments @('/changename', $benchmark, 'Thesis benchmark', 'Temporary WSL2/Kubernetes benchmark settings') | Out-Null

        # Apply settings to AC power ONLY; the user's original scheme is untouched.
        Invoke-PowerCfg -Arguments @('/setacvalueindex', $benchmark, 'SUB_PROCESSOR', 'PROCTHROTTLEMIN', '100') | Out-Null
        Invoke-PowerCfg -Arguments @('/setacvalueindex', $benchmark, 'SUB_PROCESSOR', 'PROCTHROTTLEMAX', '100') | Out-Null

        # Hybrid CPUs may provide a separate performance-state setting for class 1.
        # Avoid leaving E-cores at 100% minimum in case the original plan used that.
        $aliases = Invoke-PowerCfg -Arguments @('/aliases')
        if ($aliases -match '\bPROCTHROTTLEMIN1\b') {
            try {
                Invoke-PowerCfg -Arguments @('/setacvalueindex', $benchmark, 'SUB_PROCESSOR', 'PROCTHROTTLEMIN1', '100') | Out-Null
            }
            catch {
                Write-Warning "Could not configure class-1 minimum CPU state: $_"
            }
        }
        if ($aliases -match '\bPROCTHROTTLEMAX1\b') {
            try {
                Invoke-PowerCfg -Arguments @('/setacvalueindex', $benchmark, 'SUB_PROCESSOR', 'PROCTHROTTLEMAX1', '100') | Out-Null
            }
            catch {
                Write-Warning "Could not configure class-1 maximum CPU state: $_"
            }
        }

        if (-not $KeepBoost) {
            Invoke-PowerCfg -Arguments @('/setacvalueindex', $benchmark, 'SUB_PROCESSOR', 'PERFBOOSTMODE', '0') | Out-Null
        }

        # Some Modern Standby devices may not expose these sleep settings.
        foreach ($setting in @('STANDBYIDLE', 'HIBERNATEIDLE')) {
            try {
                Invoke-PowerCfg -Arguments @('/setacvalueindex', $benchmark, 'SUB_SLEEP', $setting, '0') | Out-Null
            }
            catch {
                Write-Warning "Could not disable $setting on this device: $_"
            }
        }

        Invoke-PowerCfg -Arguments @('/setactive', $benchmark) | Out-Null
        if ((Get-ActivePowerScheme) -ne $benchmark) {
            throw 'Temporary power scheme was not activated.'
        }

        # Only services that were running are candidates for restoration.
        if (-not $SkipServices) {
            foreach ($name in $BackgroundServices) {
                $service = Get-Service -Name $name -ErrorAction SilentlyContinue
                if ($null -ne $service -and $service.Status -eq 'Running') {
                    # Journal intent BEFORE stopping so an interrupted script can recover.
                    $state.ServicesToRestart += $name
                    Save-BenchmarkState -State $state
                    try {
                        Stop-Service -Name $name -Force -ErrorAction Stop
                        Write-Host "Service stopped: $name"
                    }
                    catch {
                        Write-Warning "Could not stop service $name : $_"
                    }
                }
            }
        }

        Write-Host ''
        Write-Host 'BENCHMARK MODE ENABLED' -ForegroundColor Green
        Write-Host "Power scheme: $benchmark"
        Write-Host 'CPU min/max (AC): 5% / 100%'
        Write-Host "Turbo Boost: $(if ($KeepBoost) { 'inherited from original scheme' } else { 'disabled (power plan)' })"
        Write-Host 'Core parking: unchanged'
        Write-Host 'P/E-core scheduling: unchanged'
        Write-Host "State file: $StateFile"
        Show-CurrentLoad
        Write-Host ''
        Write-Host 'Before tests: connect AC, close background applications, monitor CPU temperature.'
        Write-Host 'After tests: .\stabilize_windows.ps1 -Restore'
        Write-Host 'NOTE: This does not pin WSL2 vCPUs to physical P-cores or E-cores.'
        exit 0
    }
    catch {
        Write-Warning "Setup failed: $_"
        Write-Warning 'Attempting automatic rollback.'
        $recovered = Restore-BenchmarkState -SavedState $state
        if (-not $recovered) {
            Write-Warning 'Run the script with -Restore after resolving the reported error.'
        }
        exit 1
    }
}
catch {
    Write-Error $_
    exit 1
}
