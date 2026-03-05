<#
.SYNOPSIS
    Datto RMM Agent Universal Fix Script

.DESCRIPTION
    Monitors and remediates Datto RMM agent (CagService) failures automatically.

    Behavior:
        1. Waits 5 minutes for system stabilization
        2. Checks CagService status
        3. If stopped: Attempts service restart (90 second timeout)
        4. If restart fails: Checks event log for service failures (lookback window)
        5. If BOTH conditions are true:
              (A) CagService is still NOT Running
              (B) A qualifying CagService failure event is present within the lookback window
           ...then performs full agent reinstall
        6. Uploads logs to S3 (via Lambda URL) ONLY when:
              - A service restart resolves the issue, OR
              - A full remediation is performed

    Deployment:
        - GPO: Deploy via Group Policy scheduled task (domain-joined devices)
        - Intune: Deploy via Platform Scripts (non-domain devices)
        - Datto: Deploy via Datto RMM component (when RMM is healthy)

.PARAMETER LambdaUrl
    Optional Lambda function URL for centralized S3 log uploads.
    If not provided, logs are only stored locally.

.PARAMETER Platform
    Datto RMM platform name (default: "vidal")

.PARAMETER EventLookbackHours
    How far back to look for relevant service failure events (default: 24)

.EXAMPLE
    # Run with S3 logging
    .\Datto_RMM_Universal_Fix.ps1 -LambdaUrl "https://your-lambda-url.amazonawsaws.com/"

.EXAMPLE
    # Run without S3 logging (local logs only)
    .\Datto_RMM_Universal_Fix.ps1

.NOTES
    Version: 2.2.0
    Requires: PowerShell 5.1+, Windows 10/11, Datto RMM agent previously installed
    Logs: C:\ProgramData\Datto_RMM_Logs\
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$LambdaUrl = "",

    [Parameter(Mandatory=$false)]
    [string]$Platform = "vidal",

    [Parameter(Mandatory=$false)]
    [ValidateRange(1,168)]
    [int]$EventLookbackHours = 24
)

$ErrorActionPreference = 'Stop'

# =========================
# Configuration
# =========================
$ServiceName          = "CagService"
$LocalLogRoot         = "C:\ProgramData\Datto_RMM_Logs"
$StabilizationSeconds = 300   # 5 minutes
$StartTimeoutSeconds  = 90    # service start verification
$PostRemediateWaitSec = 60
$UploadOnNoAction     = $false
$RemediateEnabled     = $true
$Tls12Enforce         = $true
$StartupGraceMinutes  = 10

# Event IDs commonly seen for service failures/timeouts/crashes
$ServiceFailureEventIds = @(7000,7001,7009,7031,7034)

# Settings.json location (used to derive the "UUID" folder = siteUID)
$SettingsJsonPath = "C:\ProgramData\CentraStage\AEMAgent\Settings.json"

# =========================
# Helpers
# =========================
function Ensure-Dir {
    param([Parameter(Mandatory)] [string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Get-Timestamp {
    Get-Date -Format "yyyyMMdd_HHmmss"
}

function Get-DomainOrTenantName {
    # Prefer AD domain if joined; fallback to Azure AD tenant; else WORKGROUP
    try {
        $cs = Get-CimInstance Win32_ComputerSystem
        if ($cs.PartOfDomain -and $cs.Domain) { return $cs.Domain }
    } catch {}

    # Azure AD tenant name (best-effort)
    try {
        $ds = & dsregcmd /status 2>$null
        if ($ds) {
            $tenantLine = ($ds | Select-String -Pattern 'TenantName\s*:\s*(.+)' | Select-Object -First 1)
            if ($tenantLine) {
                $tenant = $tenantLine.Matches[0].Groups[1].Value.Trim()
                if ($tenant) { return $tenant }
            }
        }
    } catch {}

    return "WORKGROUP"
}

function Get-SiteUid {
    if (Test-Path $SettingsJsonPath) {
        try {
            $json = Get-Content -Path $SettingsJsonPath -Raw | ConvertFrom-Json
            if ($json.siteUID -and ($json.siteUID -match '^[0-9a-fA-F-]{36}$')) {
                return $json.siteUID
            }
        } catch {}
    }
    return $null
}

function Get-CagServiceFailureEvents {
    param(
        [Parameter(Mandatory)] [datetime]$StartTime
    )

    # We filter to Service Control Manager provider and the common IDs above,
    # then require explicit CagService evidence to avoid unrelated service noise.
    $filter = @{
        LogName      = 'System'
        ProviderName = 'Service Control Manager'
        Id           = $ServiceFailureEventIds
        StartTime    = $StartTime
    }

    try {
        $events = Get-WinEvent -FilterHashtable $filter -ErrorAction Stop
    } catch {
        # Older systems / permissions: fall back to empty
        return @()
    }

    $hits = foreach ($e in $events) {
        $msg = $e.Message
        if ($msg -match '(?i)\bCagService\b') {
            [PSCustomObject]@{
                TimeCreated = $e.TimeCreated
                Id          = $e.Id
                Provider    = $e.ProviderName
                Message     = ($msg -replace '\s+', ' ').Trim()
            }
        }
    }

    return @($hits | Sort-Object TimeCreated -Descending)
}

function Invoke-LambdaUpload {
    param(
        [Parameter(Mandatory)] [string]$Mode,      # "restart" | "remediation" | "noaction"
        [Parameter(Mandatory)] [string]$DomainName,
        [Parameter(Mandatory)] [string]$DeviceName,
        [Parameter(Mandatory)] [string]$UuidFolder,
        [Parameter(Mandatory)] [string]$LogPath
    )

    if ([string]::IsNullOrWhiteSpace($LambdaUrl)) { return }

    # Folder preference:
    #   Service Restarts --> UUID --> Device
    #   Remediations     --> UUID --> Device
    $prefixRoot = switch ($Mode) {
        'restart'     { 'ServiceRestarts' }
        'remediation' { 'Remediations' }
        default       { 'NoAction' }
    }
    $prefix     = "$prefixRoot/$UuidFolder/$DeviceName"

    $fileName   = Split-Path $LogPath -Leaf

    # Send log contents as text body.
    # Your Lambda can key off query params to place into S3.
    $uri = "{0}?mode={1}&domain={2}&device={3}&uuid={4}&prefix={5}&s3filename={6}&ts={7}" -f `
        $LambdaUrl,
        [uri]::EscapeDataString($Mode),
        [uri]::EscapeDataString($DomainName),
        [uri]::EscapeDataString($DeviceName),
        [uri]::EscapeDataString($UuidFolder),
        [uri]::EscapeDataString($prefix),
        [uri]::EscapeDataString($fileName),
        [uri]::EscapeDataString((Get-Date).ToString("o"))

    try {
        $body = Get-Content -Path $LogPath -Raw -ErrorAction Stop
        Invoke-RestMethod -Method Post -Uri $uri -Body $body -ContentType 'text/plain' -TimeoutSec 30 | Out-Null
    } catch {
        # Don't fail the whole fix if logging fails
        Write-Warning "S3/Lambda upload failed: $($_.Exception.Message)"
    }
}

# Datto component environment variable overrides (if provided)
if (-not [string]::IsNullOrWhiteSpace($env:LAMBDA_URL)) { $LambdaUrl = $env:LAMBDA_URL.Trim() }
if (-not [string]::IsNullOrWhiteSpace($env:DATTO_PLATFORM)) { $Platform = $env:DATTO_PLATFORM.Trim().ToLower() }
if ($env:EVENT_LOOKBACK_HOURS -match '^\d+$') {
    $candidate = [int]$env:EVENT_LOOKBACK_HOURS
    if ($candidate -ge 1 -and $candidate -le 168) { $EventLookbackHours = $candidate }
}
if ($env:STABILIZATION_SECONDS -match '^\d+$') { $StabilizationSeconds = [int]$env:STABILIZATION_SECONDS }
if ($env:START_TIMEOUT_SECONDS -match '^\d+$') { $StartTimeoutSeconds = [int]$env:START_TIMEOUT_SECONDS }
if ($env:POST_REMEDIATE_WAIT_SECONDS -match '^\d+$') { $PostRemediateWaitSec = [int]$env:POST_REMEDIATE_WAIT_SECONDS }
if (-not [string]::IsNullOrWhiteSpace($env:LOG_ROOT)) { $LocalLogRoot = $env:LOG_ROOT.Trim() }
if ($env:UPLOAD_ON_NO_ACTION -match '^(?i:true|false)$') { $UploadOnNoAction = [bool]::Parse($env:UPLOAD_ON_NO_ACTION) }
if ($env:REMEDIATE_ENABLED -match '^(?i:true|false)$') { $RemediateEnabled = [bool]::Parse($env:REMEDIATE_ENABLED) }
if ($env:TLS12_ENFORCE -match '^(?i:true|false)$') { $Tls12Enforce = [bool]::Parse($env:TLS12_ENFORCE) }
if ($env:STARTUP_GRACE_MINUTES -match '^\d+$') { $StartupGraceMinutes = [int]$env:STARTUP_GRACE_MINUTES }

# Service control paths require elevated context.
try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host "ERROR: Script must run elevated (Administrator/SYSTEM). Exiting."
        exit 1
    }
} catch {
    Write-Host "ERROR: Unable to validate execution context. Exiting."
    exit 1
}

# =========================
# Start logging
# =========================
Ensure-Dir $LocalLogRoot

$DomainName   = Get-DomainOrTenantName
$DeviceName   = $env:COMPUTERNAME
$Timestamp    = Get-Timestamp
$LogFileName  = "{0}_{1}_{2}.log" -f $DomainName, $DeviceName, $Timestamp
$LogPath      = Join-Path $LocalLogRoot $LogFileName
$ActionTaken  = "none"

$transcribing = $false
try {
    Start-Transcript -Path $LogPath -Append | Out-Null
    $transcribing = $true
} catch {
    # If transcript can't start, we still continue with best-effort Write-Host
}

function Write-LogLine {
    param([Parameter(Mandatory)][string]$Message)
    $line = "{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    try { Add-Content -Path $LogPath -Value $line -ErrorAction SilentlyContinue } catch {}
    Write-Host $line
}

Write-LogLine "===== Datto RMM Universal Fix starting at $(Get-Date) on $DeviceName ====="
Write-LogLine "Domain/Tenant: $DomainName"
Write-LogLine "Platform: $Platform"
Write-LogLine "Event lookback: $EventLookbackHours hour(s)"
Write-LogLine "Remediation enabled: $RemediateEnabled"
Write-LogLine "Upload on no action: $UploadOnNoAction"
Write-LogLine "Startup grace window: $StartupGraceMinutes minute(s)"
Write-LogLine "Waiting $([int]($StabilizationSeconds/60)) minutes before checking $ServiceName to allow system services to stabilize..."
Start-Sleep -Seconds $StabilizationSeconds

# =========================
# Core logic
# =========================
$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if (-not $svc) {
    Write-LogLine "Service '$ServiceName' not found. Exiting."
    goto Done
}

$svc.Refresh()
Write-LogLine "Initial $ServiceName status: $($svc.Status)"

# IMPORTANT CHANGE:
# If service is currently Running, we do NOT remediate based on historical events.
if ($svc.Status -eq 'Running') {
    Write-LogLine "$ServiceName is Running. No action taken (ignoring historical failure events by design)."
    goto Done
}

# Service is NOT running -> attempt start
Write-LogLine "$ServiceName is NOT Running. Attempting to start service (timeout ${StartTimeoutSeconds}s)..."
$startSucceeded = $false

try {
    Start-Service -Name $ServiceName -ErrorAction Stop
} catch {
    Write-LogLine "Start-Service threw exception: $($_.Exception.Message)"
}

# Wait up to timeout for Running
$deadline = (Get-Date).AddSeconds($StartTimeoutSeconds)
do {
    Start-Sleep -Seconds 5
    $svc.Refresh()
    Write-LogLine "Waiting for $ServiceName... current status: $($svc.Status)"
    if ($svc.Status -eq 'Running') { $startSucceeded = $true; break }
} while ((Get-Date) -lt $deadline)

if ($startSucceeded) {
    Write-LogLine "SUCCESS: $ServiceName started and is Running. No full remediation required."
    $ActionTaken = "restart"

    # Upload ONLY because restart resolved a stopped service
    $siteUid = Get-SiteUid
    if (-not $siteUid) { $siteUid = "UnknownUUID" }
    Invoke-LambdaUpload -Mode "restart" -DomainName $DomainName -DeviceName $DeviceName -UuidFolder $siteUid -LogPath $LogPath

    goto Done
}

Write-LogLine "Start attempt did not result in Running state."

# Now (and ONLY now) check for qualifying failure events within lookback window
$lookbackStart = (Get-Date).AddHours(-1 * $EventLookbackHours)
Write-LogLine "Checking System event log for qualifying service failure events since $lookbackStart (Provider: Service Control Manager, IDs: $($ServiceFailureEventIds -join ','))..."
$failEvents = Get-CagServiceFailureEvents -StartTime $lookbackStart

if (-not $failEvents -or $failEvents.Count -eq 0) {
    Write-LogLine "No qualifying $ServiceName failure events found in the last $EventLookbackHours hour(s)."
    Write-LogLine "Per safety logic, skipping full remediation (service is not running but no corroborating failure events)."
    goto Done
}

Write-LogLine "Found $($failEvents.Count) qualifying failure event(s). Most recent:"
Write-LogLine ("  - {0} | ID {1} | {2}" -f $failEvents[0].TimeCreated, $failEvents[0].Id, $failEvents[0].Message)

# BOTH conditions met:
# (A) service not running
# (B) failure event exists
if (-not $RemediateEnabled) {
    Write-LogLine "Remediation is disabled by configuration (REMEDIATE_ENABLED=FALSE). Exiting without reinstall."
    goto Done
}

if ($StartupGraceMinutes -gt 0) {
    try {
        $bootAt = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime
        $uptime = (Get-Date) - $bootAt
        if ($uptime.TotalMinutes -lt $StartupGraceMinutes) {
            Write-LogLine ("Inside startup grace window ({0:N1} < {1} minutes). Skipping full remediation to avoid transient startup churn." -f $uptime.TotalMinutes, $StartupGraceMinutes)
            goto Done
        }
    } catch {
        Write-LogLine "WARNING: Could not calculate uptime for startup grace evaluation: $($_.Exception.Message)"
    }
}

Write-LogLine "Both conditions met (service not Running + failure event detected). Proceeding with FULL REMEDIATION (agent reinstall)."
$ActionTaken = "remediation"

# =========================
# Full remediation
# =========================
# Determine siteUID before any destructive change
$siteUid = Get-SiteUid
if (-not $siteUid) {
    Write-LogLine "ERROR: Unable to read valid siteUID from $SettingsJsonPath. Aborting full remediation before any changes."
    goto Done
} else {
    Write-LogLine "Using siteUID (UUID folder): $siteUid"
}

# Preflight download before changing service/files
if ($Tls12Enforce) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}

$downloadUrl = "https://$Platform.rmm.datto.com/download-agent/windows/$siteUid"
$tempExe     = Join-Path $env:TEMP ("AgentInstall_{0}.exe" -f $siteUid)

Write-LogLine "Preflight: downloading agent installer before mutation: $downloadUrl"
try {
    Invoke-WebRequest -Uri $downloadUrl -OutFile $tempExe -UseBasicParsing -ErrorAction Stop
    if (-not (Test-Path $tempExe)) {
        throw "Installer not found at expected path after download."
    }

    $downloaded = Get-Item -Path $tempExe -ErrorAction Stop
    if ($downloaded.Length -le 0) {
        throw "Downloaded installer is empty."
    }

    Write-LogLine "Preflight download complete: $tempExe ($($downloaded.Length) bytes)"
} catch {
    Write-LogLine "ERROR: Preflight download failed. Aborting before service/file changes: $($_.Exception.Message)"
    goto Done
}

try { Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue } catch {}

# Rename agent dir (forensics)
$agentDir = "C:\ProgramData\CentraStage"
if (Test-Path $agentDir) {
    $backupName = "CentraStage.OLD_{0}" -f (Get-Timestamp)
    $backupPath = Join-Path (Split-Path $agentDir -Parent) $backupName
    Write-LogLine "Renaming '$agentDir' -> '$backupPath'"
    try {
        Rename-Item -Path $agentDir -NewName $backupName -Force
    } catch {
        Write-LogLine "ERROR: Failed to rename agent directory: $($_.Exception.Message)"
    }
} else {
    Write-LogLine "Agent directory not found at $agentDir (continuing)."
}

Write-LogLine "Running installer silently..."
try {
    $p = Start-Process -FilePath $tempExe -ArgumentList "/S" -Wait -PassThru -ErrorAction Stop
    Write-LogLine "Installer exit code: $($p.ExitCode)"
} catch {
    Write-LogLine "ERROR: Installer execution failed: $($_.Exception.Message)"
}

try { Remove-Item $tempExe -Force -ErrorAction SilentlyContinue } catch {}

Write-LogLine "Waiting $PostRemediateWaitSec seconds, then re-checking $ServiceName..."
Start-Sleep -Seconds $PostRemediateWaitSec

$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($svc) { $svc.Refresh() }

if ($svc -and $svc.Status -eq 'Running') {
    Write-LogLine "SUCCESS: $ServiceName is Running after FULL REMEDIATION."
} else {
    $st = if ($svc) { $svc.Status } else { "NotFound" }
    Write-LogLine "FAILURE: $ServiceName is not Running after FULL REMEDIATION. Status: $st"
}

# Upload ONLY because full remediation was performed
Invoke-LambdaUpload -Mode "remediation" -DomainName $DomainName -DeviceName $DeviceName -UuidFolder $siteUid -LogPath $LogPath

# =========================
# Done
# =========================
:Done
if ($ActionTaken -eq "none" -and $UploadOnNoAction) {
    $siteUid = Get-SiteUid
    if (-not $siteUid) { $siteUid = "UnknownUUID" }
    Invoke-LambdaUpload -Mode "noaction" -DomainName $DomainName -DeviceName $DeviceName -UuidFolder $siteUid -LogPath $LogPath
}

Write-LogLine "===== Datto RMM Universal Fix finished at $(Get-Date) on $DeviceName ====="

if ($transcribing) {
    try { Stop-Transcript | Out-Null } catch {}
}
