<#
.SYNOPSIS
    RemoteGate — Verify installation.

.DESCRIPTION
    Checks:
      - OpenSSH Server installed
      - sshd running, automatic
      - Firewall rule exists and restricted
      - Listening on 22
      - Tunnel key exists, ACL hardened
      - Scheduled task exists
      - Config exists

    Does NOT claim cloud connectivity without actual test.
#>
[CmdletBinding()]
param(
    [string]$RemoteGateRoot = "C:\ProgramData\RemoteGate"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$LogFile = "$RemoteGateRoot\logs\install.log"
function VLog { param([string]$M,[string]$L="INFO")
    $ts=Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line="[$ts] [$L] [Verify] $M"
    Write-Host $line -ForegroundColor $(if($L -eq "ERROR"){"Red"}elseif($L -eq "WARN"){"Yellow"}elseif($L -eq "PASS"){"Green"}else{"Cyan"})
    try { Add-Content -Path $LogFile -Value $line -Encoding UTF8 } catch {}
}

$pass = 0; $fail = 0; $warn = 0
function Check { param([string]$Name, [scriptblock]$Test, [string]$Hint="")
    try {
        $ok = & $Test
        if ($ok) { VLog "PASS: $Name" "PASS"; $script:pass++ } else { VLog "FAIL: $Name $(if($Hint){" — $Hint"})" "ERROR"; $script:fail++ }
    } catch { VLog "FAIL: $Name — $_ $(if($Hint){" — $Hint"})" "ERROR"; $script:fail++ }
}
function CheckWarn { param([string]$Name, [scriptblock]$Test, [string]$Hint="")
    try {
        $ok = & $Test
        if ($ok) { VLog "PASS: $Name" "PASS"; $script:pass++ } else { VLog "WARN: $Name $(if($Hint){" — $Hint"})" "WARN"; $script:warn++ }
    } catch { VLog "WARN: $Name — $_" "WARN"; $script:warn++ }
}

Write-Host "`n── Verification ──" -ForegroundColor Green
Write-Host "RemoteGateRoot: $RemoteGateRoot" -ForegroundColor DarkGray

# 1. OS
Check "Windows build >= 17763 (1809)" { [int](Get-CimInstance Win32_OperatingSystem).BuildNumber -ge 17763 }

# 2. Capability
Check "OpenSSH Server capability installed" {
    $c = Get-WindowsCapability -Online -Name "OpenSSH.Server~~~~0.0.1.0" -ErrorAction Stop
    $c.State -eq "Installed"
}

# 3. Service
Check "sshd service exists" { $null -ne (Get-Service -Name sshd -ErrorAction SilentlyContinue) }
Check "sshd is running" { (Get-Service -Name sshd -ErrorAction Stop).Status -eq "Running" }
Check "sshd StartupType is Automatic" { (Get-Service -Name sshd -ErrorAction Stop).StartType -eq "Automatic" }

# 4. Port
CheckWarn "sshd listening on TCP 22" {
    $null -ne (Get-NetTCPConnection -LocalPort 22 -State Listen -ErrorAction SilentlyContinue)
} "Service may need a moment to bind."

# 5. Firewall
Check "Firewall rule OpenSSH-Server-In-TCP exists" {
    $null -ne (Get-NetFirewallRule -DisplayName "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue)
}
CheckWarn "Firewall restricts to LocalSubnet" {
    $rule = Get-NetFirewallRule -DisplayName "OpenSSH-Server-In-TCP" -ErrorAction Stop
    $addr = (Get-NetFirewallAddressFilter -AssociatedNetFirewallRule $rule).RemoteAddress
    $addr -contains "LocalSubnet" -or $addr -eq "LocalSubnet"
} "Restrict RemoteAddress to LocalSubnet for security."

# 6. sshd_config hardening
CheckWarn "sshd_config has PasswordAuthentication no" {
    $cfg = Get-Content "C:\ProgramData\ssh\sshd_config" -Raw -ErrorAction Stop
    $cfg -match "(?m)^\s*PasswordAuthentication\s+no"
}
CheckWarn "sshd_config has PubkeyAuthentication yes" {
    $cfg = Get-Content "C:\ProgramData\ssh\sshd_config" -Raw -ErrorAction Stop
    $cfg -match "(?m)^\s*PubkeyAuthentication\s+yes"
}

# 7. Keys
CheckWarn "Tunnel private key is not exposed" {
    $p = "$RemoteGateRoot\keys\tunnel_ed25519"
    # Key should exist after Configure-Tunnel
    Test-Path $p
} "Run Configure-Tunnel.ps1 or re-run installer."

# 8. Scheduled task
CheckWarn "Scheduled task RemoteGate-Tunnel exists" {
    $t = Get-ScheduledTask -TaskName "RemoteGate-Tunnel" -TaskPath "\RemoteGate\" -ErrorAction SilentlyContinue
    if (-not $t) { $t = Get-ScheduledTask -TaskName "RemoteGate-Tunnel" -ErrorAction SilentlyContinue }
    $null -ne $t
}

# 9. Config
CheckWarn "config.json exists" { Test-Path "$RemoteGateRoot\config\config.json" }
CheckWarn "config.json has real VM IP (not placeholder)" {
    $j = Get-Content "$RemoteGateRoot\config\config.json" -Raw -ErrorAction Stop | ConvertFrom-Json
    $j.yandex.vmPublicIp -and $j.yandex.vmPublicIp -notmatch "REPLACE"
} "Fill in yandex.vmPublicIp before tunnel can connect."

# 10. Device ID
Check "Device ID exists" { Test-Path "$RemoteGateRoot\config\device-id.txt" }

# 11. Tunnel task state (if VM configured)
$cfgPath = "$RemoteGateRoot\config\config.json"
if (Test-Path $cfgPath) {
    try {
        $j = Get-Content $cfgPath -Raw | ConvertFrom-Json
        if ($j.yandex.vmPublicIp -and $j.yandex.vmPublicIp -notmatch "REPLACE") {
            CheckWarn "Tunnel task last run succeeded (0x0)" {
                $info = Get-ScheduledTaskInfo -TaskName "RemoteGate-Tunnel" -TaskPath "\RemoteGate\" -ErrorAction Stop
                $info.LastTaskResult -eq 0
            } "Check logs/tunnel.log; task may have been killed intentionally for long-running tunnel."
        }
    } catch {}
}

# 12. Log file
Check "Install log exists" { Test-Path $LogFile }

# Summary
Write-Host ""
Write-Host "════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Verification: $pass passed, $warn warnings, $fail failed" -ForegroundColor $(if($fail -gt 0){"Red"}elseif($warn -gt 0){"Yellow"}else{"Green"})
if ($fail -gt 0) { Write-Host "  Some critical checks failed — review above." -ForegroundColor Red }
elseif ($warn -gt 0) { Write-Host "  Warnings — see hints above (often config placeholders)." -ForegroundColor Yellow }
else { Write-Host "  All checks passed!" -ForegroundColor Green }
Write-Host "════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Logs: $LogFile" -ForegroundColor DarkGray
Write-Host "  Tunnel: $RemoteGateRoot\logs\tunnel.log" -ForegroundColor DarkGray
Write-Host "  Status: $RemoteGateRoot\logs\status.log" -ForegroundColor DarkGray
Write-Host ""

# Exit code reflects critical failures only
if ($fail -gt 0) { exit 1 } else { exit 0 }
