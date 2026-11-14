<#
  Security-focused static tests — verify no secrets, no insecure patterns.
  Tag: security
#>
BeforeAll {
  $script:RepoRoot = Join-Path $PSScriptRoot "../.."
  $script:AllTrackedFiles = Get-ChildItem $RepoRoot -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch "\.git[\\/]" -and $_.FullName -notmatch "Unselected files" } |
    Where-Object { $_.Extension -in @(".ps1",".sh",".js",".yaml",".yml",".json",".tf",".md") }
}

Describe "No secrets in repository" -Tag "security" {
  It "does not contain private keys (BEGIN markers)" {
    $hits = @()
    foreach ($f in $AllTrackedFiles) {
      $content = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
      if ($content -match "BEGIN (?:OPENSSH|RSA|DSA|EC) PRIVATE KEY") {
        $hits += $f.FullName
      }
    }
    $hits | Should -BeNullOrEmpty -Because "No private key should be committed. Found in: $($hits -join ', ')"
  }

  It "does not use DEIN_PASSWORT as real credential" {
    $hits = @()
    foreach ($f in $AllTrackedFiles) {
      # Templates/examples intentionally contain DEIN_PASSWORT as placeholder sentinel
      if ($f.FullName -match "templates[\\/]" -or $f.FullName -match "generator[\\/].*Example") { continue }
      $content = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
      # Allow sentinel check (e.g. WindowsPassword -eq/-ne "DEIN_PASSWORT") — not a credential use
      # Flag only when assigned as actual password value without sentinel logic
      if ($content -match 'DEIN_PASSWORT') {
        # If file contains sentinel check, it's intentional placeholder handling
        if ($content -match '\-eq\s*["'']DEIN_PASSWORT["'']|\-ne\s*["'']DEIN_PASSWORT["'']') { continue }
        if ($content -match 'password\s*[=:].*DEIN_PASSWORT|SecureString.*DEIN_PASSWORT') {
          $hits += $f.FullName
        }
      }
    }
    $hits | Should -BeNullOrEmpty
  }

  It ".gitignore excludes secrets" {
    $gi = Join-Path $RepoRoot ".gitignore"
    Test-Path $gi | Should -Be $true
    $content = Get-Content $gi -Raw
    $content | Should -Match "\.pem|\.key|hmac-secret|secrets"
  }

  It "no hardcoded Yandex API keys or tokens" {
    $hits = @()
    foreach ($f in $AllTrackedFiles) {
      $c = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
      if ($c -match "AQVN[A-Za-z0-9_\-]{20,}" -or $c -match "y0_[A-Za-z0-9_\-]{20,}") {
        $hits += $f.FullName
      }
    }
    $hits | Should -BeNullOrEmpty -Because "Yandex IAM tokens/API keys must not be in repo"
  }
}

Describe "No insecure SSH patterns" -Tag "security" {
  It "no StrictHostKeyChecking=no in repo" {
    $hits = @()
    foreach ($f in $AllTrackedFiles) {
      $c = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
      if ($c -match "StrictHostKeyChecking\s+no") {
        # Allow in comments that say "Never do ...no" but not active code
        $lines = $c -split "`n" | Where-Object { $_ -match "StrictHostKeyChecking\s+no" -and $_ -notmatch "Never|Do not|Prohibited" }
        if ($lines) { $hits += $f.FullName }
      }
    }
    $hits | Should -BeNullOrEmpty
  }

  It "no PasswordAuthentication yes hardening bypass (unless explicit conditional)" {
    # Original installer defaults to no; template enables yes ONLY when explicit $UsePasswordAuth (fixed password opt-in)
    $scripts = $AllTrackedFiles | Where-Object { $_.Extension -eq ".ps1" }
    $hits = @()
    foreach ($f in $scripts) {
      $c = Get-Content $f.FullName -Raw
      # Skip files that have conditional logic (UsePasswordAuth) — explicit user opt-in via wizard
      if ($c -match "UsePasswordAuth" -or $c -match "PasswordAuthentication.*yes.*explicit|festes Passwort") { continue }
      if ($c -match "PasswordAuthentication\s+yes" -and $f.Name -notlike "*.Tests.ps1" -and $f.Name -ne "Bootstrap.ps1") {
        # Also ignore docs/comments that say "PasswordAuthentication yes" as example of what NOT to do
        $lines = $c -split "`n" | Where-Object { $_ -match "PasswordAuthentication\s+yes" -and $_ -notmatch "Never|Do not|Platzhalter|Beispiel|NOT to do" }
        if ($lines) { $hits += "$($f.Name): PasswordAuthentication yes in non-test/script" }
      }
    }
    $hits | Should -BeNullOrEmpty
  }

  It "firewall not exposing 22 to Any by default" {
    # Installer should set LocalSubnet
    $fw = Join-Path $RepoRoot "installer/Configure-Firewall.ps1"
    if (Test-Path $fw) {
      $c = Get-Content $fw -Raw
      $c | Should -Match "LocalSubnet"
    }
  }
}
