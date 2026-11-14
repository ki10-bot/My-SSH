<#
  Tests for generator workflow (DEIN_PASSWORT placeholder, Yandex upload, templating)
  Tag: unit, generator
#>
BeforeAll {
  $RepoRoot = Join-Path $PSScriptRoot "../.."
  $TemplatePath = Join-Path $RepoRoot "templates/RemoteGate-Deployment.template.ps1"
  $WizardPath = Join-Path $RepoRoot "generator/New-RemoteGateDeployment.ps1"
  $UploaderPath = Join-Path $RepoRoot "generator/Upload-ToYandex.ps1"
  $ExamplePath = Join-Path $RepoRoot "generator/Example-Install.ps1.example"
}

Describe "Generator workflow" -Tag "unit" {
  It "template exists and contains DEIN_PASSWORT placeholder (not real password)" {
    Test-Path $TemplatePath | Should -Be $true
    $t = Get-Content $TemplatePath -Raw
    $t | Should -Match "DEIN_PASSWORT"
    $t | Should -Match "__WINDOWS_PASSWORD__"
    $t.Length | Should -BeGreaterThan 5000
  }

  It "template uses Yandex placeholders (DEIN_YANDEX_VM_IP, bucket etc.)" {
    $t = Get-Content $TemplatePath -Raw
    $t | Should -Match "__YANDEX_VM_IP__"
    $t | Should -Match "__YANDEX_BUCKET__"
    $t | Should -Match "__DEVICE_ID__"
  }

  It "wizard exists and prompts for password with SecureString" {
    Test-Path $WizardPath | Should -Be $true
    $w = Get-Content $WizardPath -Raw
    $w | Should -Match "Read-SecureInput|AsSecureString"
    $w | Should -Match "Festes Passwort|DEIN_PASSWORT"
  }

  It "wizard injects placeholders (Replace)" {
    $w = Get-Content $WizardPath -Raw
    $w | Should -Match "\.Replace\("
    $w | Should -Match "__WINDOWS_PASSWORD__"
  }

  It "wizard writes to dist/ (gitignored) and never commits password" {
    $gi = Get-Content (Join-Path $RepoRoot ".gitignore") -Raw
    $gi | Should -Match "dist/"
    $gi | Should -Match "generated"
    Test-Path $WizardPath | Should -Be $true
    # Check wizard does not have git add/commit of dist
    $w = Get-Content $WizardPath -Raw
    $w | Should -Not -Match "git add.*dist"
  }

  It "uploader supports yc and aws with private default" {
    Test-Path $UploaderPath | Should -Be $true
    $u = Get-Content $UploaderPath -Raw
    $u | Should -Match "storage\.yandexcloud\.net"
    $u | Should -Match "private" # default
    $u | Should -Match "presign|presigned"
  }

  It "example file shows DEIN_PASSWORT workflow steps (1-8)" {
    Test-Path $ExamplePath | Should -Be $true
    $e = Get-Content $ExamplePath -Raw
    $e | Should -Match "DEIN_PASSWORT"
    $e | Should -Match "Wizard|Generator"
    $e | Should -Match "storage\.yandexcloud\.net"
  }

  It "final installer source is Yandex, not GitHub raw, in wizard output" {
    $w = Get-Content $WizardPath -Raw
    $w | Should -Match "storage\.yandexcloud\.net"
    $w | Should -Not -Match "raw\.githubusercontent.*RemoteGate-Final"
  }

  It "docs/GENERATOR.md documents 8 steps" {
    $doc = Join-Path $RepoRoot "docs/GENERATOR.md"
    Test-Path $doc | Should -Be $true
    $d = Get-Content $doc -Raw
    $d | Should -Match "8 Schritte|8 Schritten|Workflow"
    $d | Should -Match "DEIN_PASSWORT"
    $d | Should -Match "Upload.*Yandex"
  }
}
