<#
.SYNOPSIS
    RemoteGate — Configure Windows Firewall for SSH.

.DESCRIPTION
    - Verifies the default OpenSSH-Server-In-TCP rule exists
    - Optionally restricts it to local subnet / private profiles
    - Ensures port 22 is NOT exposed to public Internet
    - Idempotent

.PARAMETER RemoteGateRoot
    Root dir for logs.
.PARAMETER ConfigPath
    Path to config.json (reads firewallRestrictToLocalSubnet)
#>
[CmdletBinding()]
param(
    [string]$RemoteGateRoot = "C:\ProgramData\RemoteGate",
    [string]$ConfigPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$LogFile = "$RemoteGateRoot\logs\install.log"
function Write-FWLog { param([string]$M,[string]$L="INFO")
    $ts=Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line="[$ts] [$L] [Configure-Firewall] $M"
    Write-Host $line -ForegroundColor $(if($L -eq "ERROR"){"Red"}elseif($L -eq "WARN"){"Yellow"}else{"Cyan"})
    try { Add-Content -Path $LogFile -Value $line -Encoding UTF8 } catch {}
}

Write-Host "`n[Configure-Firewall] Configuring Windows Firewall..." -ForegroundColor Cyan

if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-FWLog "Administrator required." "ERROR"
    throw "Configure-Firewall.ps1 must run elevated."
}

$restrictToLocal = $true
if ($ConfigPath -and (Test-Path $ConfigPath)) {
    try {
        $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
        if ($null -ne $cfg.security.firewallRestrictToLocalSubnet) { $restrictToLocal = [bool]$cfg.security.firewallRestrictToLocalSubnet }
    } catch { Write-FWLog "Config parse failed: $_" "WARN" }
}
Write-FWLog "Restrict to local subnet: $restrictToLocal"

# ── Check existing rule ────────────────────────────────────────────────
$ruleName = "OpenSSH-Server-In-TCP"
$rule = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue

if (-not $rule) {
    Write-FWLog "Firewall rule '$ruleName' not found — creating it." "WARN"
    try {
        New-NetFirewallRule -Name $ruleName -DisplayName $ruleName `
            -Enabled True -Direction Inbound -Protocol TCP -LocalPort 22 `
            -Action Allow -Profile Any | Out-Null
        Write-FWLog "Created rule $ruleName"
        $rule = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction Stop
    } catch {
        Write-FWLog "Failed to create firewall rule: $_" "ERROR"
        throw
    }
} else {
    Write-FWLog "Found rule '$ruleName' — Enabled=$($rule.Enabled) Direction=$($rule.Direction)"
    # Ensure it's enabled
    if ($rule.Enabled -ne "True") {
        Enable-NetFirewallRule -DisplayName $ruleName
        Write-FWLog "Enabled rule $ruleName"
    }
}

# ── Restrict to local subnet where practical ───────────────────────────
# The requirement: "Restrict inbound SSH access to the local network where practical.
# Do not expose Windows TCP port 22 directly to the public Internet."

# We do NOT remove the ability to function on local network.
# Strategy:
#   - Set RemoteAddress to LocalSubnet (if restrictToLocal = true)
#   - Otherwise keep Any (default) but warn user

if ($restrictToLocal) {
    try {
        # Get current remote address filter
        $addrFilter = Get-NetFirewallAddressFilter -AssociatedNetFirewallRule $rule -ErrorAction SilentlyContinue
        Write-FWLog "Current RemoteAddress: $($addrFilter.RemoteAddress)"

        # Only change if currently Any
        if ($addrFilter.RemoteAddress -contains "Any" -or $addrFilter.RemoteAddress -eq "Any") {
            # Restrict to LocalSubnet — Windows Firewall keyword
            Set-NetFirewallRule -DisplayName $ruleName -RemoteAddress LocalSubnet -ErrorAction Stop
            Write-FWLog "Restricted $ruleName RemoteAddress to LocalSubnet (loopback + local network only)."
            Write-Host "[Configure-Firewall] Restricted SSH to local subnet (private networks only)." -ForegroundColor Green
            Write-Host "  This prevents direct public Internet exposure of port 22." -ForegroundColor DarkGray
            Write-Host "  Remote access via Yandex bastion uses OUTBOUND tunnel — not inbound port 22." -ForegroundColor DarkGray
        } else {
            Write-FWLog "RemoteAddress already restricted to: $($addrFilter.RemoteAddress)"
        }
    } catch {
        Write-FWLog "Could not restrict RemoteAddress: $_" "WARN"
        Write-Host "WARNING: Could not restrict firewall to LocalSubnet: $_" -ForegroundColor Yellow
    }
} else {
    Write-FWLog "Local-subnet restriction disabled per config — leaving RemoteAddress as-is." "WARN"
    Write-Host "[Configure-Firewall] WARNING: Firewall not restricted to local subnet (config override)." -ForegroundColor Yellow
    Write-Host "  Ensure your router/NAT does NOT forward port 22 to this machine." -ForegroundColor Yellow
}

# ── Ensure Domain/Private/Public profiles handling ─────────────────────
# Show current profile settings
try {
    $profileFilter = Get-NetFirewallProfile -ErrorAction SilentlyContinue | Select-Object Name, Enabled
    Write-FWLog "Firewall profiles: $($profileFilter | Out-String)"
} catch {}

# ── Create explicit RemoteGate block rule for documentation ─────────────
# An additional rule that makes the security posture visible in firewall UI
$blockRuleName = "RemoteGate-Block-Public-SSH"
$existingBlock = Get-NetFirewallRule -DisplayName $blockRuleName -ErrorAction SilentlyContinue
if (-not $existingBlock) {
    # This is informational — actual restriction is via LocalSubnet above
    # We create a disabled example rule showing intent (user can enable if they want extra blocking)
    try {
        New-NetFirewallRule -DisplayName $blockRuleName `
            -Description "RemoteGate: Example block rule — enable to explicitly block SSH from public Internet. The primary protection is the LocalSubnet restriction on OpenSSH-Server-In-TCP." `
            -Direction Inbound -Protocol TCP -LocalPort 22 -RemoteAddress Internet `
            -Action Block -Enabled False -Profile Any | Out-Null
        Write-FWLog "Created informational rule $blockRuleName (disabled, for documentation)."
    } catch { Write-FWLog "Could not create info rule: $_" "WARN" }
}

# ── Verify ──────────────────────────────────────────────────────────────
$finalRule = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
$finalAddr = Get-NetFirewallAddressFilter -AssociatedNetFirewallRule $finalRule -ErrorAction SilentlyContinue
Write-FWLog "Final rule: Enabled=$($finalRule.Enabled) RemoteAddress=$($finalAddr.RemoteAddress)"
Write-Host "[Configure-Firewall] Firewall configured: $ruleName -> RemoteAddress=$($finalAddr.RemoteAddress)" -ForegroundColor Green

Write-FWLog "Configure-Firewall completed."
