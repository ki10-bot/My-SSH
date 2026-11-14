<#
  Pester 5 tests for RemoteGate installers.
  Run: Invoke-Pester -Path tests/powershell -Output Detailed
  Requires: Pester 5+ (Install-Module Pester -Force)
  These are unit/mocked tests — they do NOT require a real Windows install.
  Tags: unit, mock

  Integration tests that need real Windows are in tests/integration/
#>
BeforeAll {
  # Import script for static analysis (no execution)
  $script:InstallerPath = Join-Path $PSScriptRoot "../../installer/Install-RemoteGate.ps1"
  $script:ConfigureSshPath = Join-Path $PSScriptRoot "../../installer/Configure-SSH.ps1"
  $script:ConfigureFwPath = Join-Path $PSScriptRoot "../../installer/Configure-Firewall.ps1"
  $script:ConfigureTunnelPath = Join-Path $PSScriptRoot "../../installer/Configure-Tunnel.ps1"
  $script:VerifyPath = Join-Path $PSScriptRoot "../../installer/Verify-Installation.ps1"
  $script:UninstallPath = Join-Path $PSScriptRoot "../../installer/Uninstall-RemoteGate.ps1"
  $script:TunnelAgentPath = Join-Path $PSScriptRoot "../../windows/RemoteGate-Tunnel.ps1"
  $script:StatusPath = Join-Path $PSScriptRoot "../../windows/RemoteGate-Status.ps1"
}

Describe "Install-RemoteGate.ps1" -Tag "unit" {
  It "exists and is readable" {
    Test-Path $InstallerPath | Should -Be $true
    (Get-Content $InstallerPath -Raw).Length | Should -BeGreaterThan 1000
  }

  It "requires Administrator check" {
    $content = Get-Content $InstallerPath -Raw
    $content | Should -Match "IsInRole.*Administrator"
  }

  It "checks Windows build >= 17763" {
    $content = Get-Content $InstallerPath -Raw
    $content | Should -Match "MinimumBuild.*17763|17763"
    $content | Should -Match "BuildNumber|Build"
  }

  It "does not hardcode DEIN_PASSWORT as password" {
    $content = Get-Content $InstallerPath -Raw
    # DEIN_PASSWORT should not appear outside placeholder context; if it does, ensure not as password value
    if ($content -match "DEIN_PASSWORT") {
      $content | Should -Not -Match 'Password\s*=\s*["'']DEIN_PASSWORT'
      $content | Should -Not -Match 'ConvertTo-SecureString.*DEIN_PASSWORT'
    }
  }

  It "uses HTTPS GitHub URLs (not HTTP)" {
    $content = Get-Content $InstallerPath -Raw
    $content | Should -Not -Match "http://github"
    # If it mentions raw.github it should be https
  }

  It "is idempotent (mentions rerun / preserve)" {
    $content = Get-Content $InstallerPath -Raw
    $content | Should -Match "idempotent|rerun|preserve|Existing"
  }

  It "does not disable Defender / bypass UAC / obfuscate" {
    $content = Get-Content $InstallerPath -Raw
    $content | Should -Not -Match "Disable.*Defender|Disable-MpPreference"
    $content | Should -Not -Match "Bypass.*UAC|Suppress.*UAC"
    # Does not use obfuscated Invoke-Expression on remote without verify
    # Bootstrap does iex but with verify — main installer should not
    $content | Should -Not -Match "FromBase64String|EncodedCommand"
  }

  It "creates visible Scheduled Task (not hidden)" {
    # Check tunnel config script for visible task creation
    $tunnelContent = Get-Content $ConfigureTunnelPath -Raw
    $tunnelContent | Should -Match "Register-ScheduledTask"
    $tunnelContent | Should -Not -Match "-Hidden|\$hidden"
    $tunnelContent | Should -Match "Description"
  }

  It "has uninstall reference" {
    $content = Get-Content $InstallerPath -Raw
    $content | Should -Match "Uninstall"
  }
}

Describe "Configure-SSH.ps1" -Tag "unit" {
  It "exists" { Test-Path $ConfigureSshPath | Should -Be $true }

  It "installs OpenSSH Server capability" {
    $c = Get-Content $ConfigureSshPath -Raw
    $c | Should -Match "OpenSSH.Server"
    $c | Should -Match "Add-WindowsCapability"
  }

  It "sets sshd to Automatic" {
    $c = Get-Content $ConfigureSshPath -Raw
    $c | Should -Match "StartupType.*Automatic|Set-Service.*Automatic"
  }

  It "hardens sshd_config (PasswordAuthentication no)" {
    $c = Get-Content $ConfigureSshPath -Raw
    $c | Should -Match "PasswordAuthentication.*no"
    $c | Should -Match "PubkeyAuthentication.*yes"
  }

  It "keeps host key checking enabled" {
    # No StrictHostKeyChecking no
    $c = Get-Content $ConfigureSshPath -Raw
    $c | Should -Not -Match "StrictHostKeyChecking\s+no"
  }

  It "does not store credentials" {
    $c = Get-Content $ConfigureSshPath -Raw
    $c | Should -Not -Match "DEIN_PASSWORT"
  }
}

Describe "Configure-Firewall.ps1" -Tag "unit" {
  It "exists" { Test-Path $ConfigureFwPath | Should -Be $true }

  It "restricts to LocalSubnet or warns" {
    $c = Get-Content $ConfigureFwPath -Raw
    $c | Should -Match "LocalSubnet"
    $c | Should -Match "OpenSSH-Server-In-TCP"
  }

  It "does not expose 22 to Internet by default" {
    $c = Get-Content $ConfigureFwPath -Raw
    $c | Should -Not -Match "RemoteAddress.*Any.*Allow.*22"
    # Should set or verify LocalSubnet
  }
}

Describe "Configure-Tunnel.ps1" -Tag "unit" {
  It "exists" { Test-Path $ConfigureTunnelPath | Should -Be $true }

  It "generates dedicated tunnel key (not Mac key)" {
    $c = Get-Content $ConfigureTunnelPath -Raw
    $c | Should -Match "tunnel_ed25519|tunnel.*key"
    $c | Should -Match "ssh-keygen.*ed25519"
  }

  It "uses loopback-only binding 127.0.0.1:" {
    $c = Get-Content $ConfigureTunnelPath -Raw
    $c | Should -Match "127\.0\.0\.1:"
  }

  It "enables keepalive settings" {
    $c = Get-Content $ConfigureTunnelPath -Raw
    $c | Should -Match "ServerAliveInterval|ServerAliveCountMax"
  }

  It "creates Scheduled Task visible" {
    $c = Get-Content $ConfigureTunnelPath -Raw
    $c | Should -Match "Register-ScheduledTask"
    $c | Should -Match "RemoteGate-Tunnel"
  }

  It "does not reuse Mac key" {
    $c = Get-Content $ConfigureTunnelPath -Raw
    # Should mention not reusing
    $c | Should -Not -Match "remotegate_mac.*tunnel" -Or $c | Should -Match "dedicated"
  }
}

Describe "Verify-Installation.ps1" -Tag "unit" {
  It "exists" { Test-Path $VerifyPath | Should -Be $true }
  It "checks sshd running and firewall" {
    $c = Get-Content $VerifyPath -Raw
    $c | Should -Match "sshd.*Running|Get-Service.*sshd"
    $c | Should -Match "Firewall|LocalSubnet"
  }
  It "returns exit code 1 on fail" {
    $c = Get-Content $VerifyPath -Raw
    $c | Should -Match "exit 1"
  }
}

Describe "Uninstall-RemoteGate.ps1" -Tag "unit" {
  It "exists" { Test-Path $UninstallPath | Should -Be $true }
  It "removes scheduled task" {
    $c = Get-Content $UninstallPath -Raw
    $c | Should -Match "Unregister-ScheduledTask"
  }
  It "does not auto-remove OpenSSH without flag" {
    $c = Get-Content $UninstallPath -Raw
    $c | Should -Match "RemoveOpenSSH"
    # Should require switch, not default
    $c | Should -Match "param.*RemoveOpenSSH"
  }
}

Describe "RemoteGate-Tunnel.ps1" -Tag "unit" {
  It "exists" { Test-Path $TunnelAgentPath | Should -Be $true }
  It "prevents duplicates (mutex or process check)" {
    $c = Get-Content $TunnelAgentPath -Raw
    $c | Should -Match "Mutex|duplicate|other.*process"
  }
  It "logs connect/disconnect" {
    $c = Get-Content $TunnelAgentPath -Raw
    $c | Should -Match "Write-TunnelLog|tunnel\.log"
  }
  It "uses StrictHostKeyChecking yes" {
    $c = Get-Content $TunnelAgentPath -Raw
    $c | Should -Match "StrictHostKeyChecking.*yes"
    $c | Should -Not -Match "StrictHostKeyChecking.*no"
  }
  It "handles reconnection with backoff" {
    $c = Get-Content $TunnelAgentPath -Raw
    $c | Should -Match "backoff|Reconnect|Restart"
  }
}

Describe "RemoteGate-Status.ps1" -Tag "unit" {
  It "exists" { Test-Path $StatusPath | Should -Be $true }
  It "uses HTTPS and HMAC" {
    $c = Get-Content $StatusPath -Raw
    $c | Should -Match "https://"
    $c | Should -Match "HMACSHA256|hmac"
  }
  It "validates timestamp/nonce for replay protection" {
    $c = Get-Content $StatusPath -Raw
    $c | Should -Match "timestamp|nonce|replay"
  }
  It "never sends private keys/passwords" {
    $c = Get-Content $StatusPath -Raw
    $c | Should -Not -Match "Get-Content.*\.key|BEGIN PRIVATE"
  }
  It "can be disabled" {
    $c = Get-Content $StatusPath -Raw
    $c | Should -Match "enabled.*false|statusEnabled"
  }
  It "does not log secrets" {
    $c = Get-Content $StatusPath -Raw
    # Should not Write-Host $hmacSecret directly
    $c | Should -Match "Zero out|hmacSecret.*null" -Or $c | Should -Not -Match "Write-Host.*hmacSecret"
  }
}
