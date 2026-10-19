# Lab layer rehearsal (M3c, G6). Two vaults from the Release bundle, role pi
# and role grad, both linked at install time to one shared folder. Then the
# shipped scripts: a share preview that writes nothing, a share that lands and
# is readable from the other vault through its own link, and the link check.
# The full two-vault suite lives in the installer tests; this is the headless
# subset the CI job can prove on a runner.
param(
    [Parameter(Mandatory)][string]$Bundle,
    [Parameter(Mandatory)][string]$Work,
    [string]$Console = ""
)
$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false
$script:fails = 0; $script:passes = 0
function Check([bool]$ok, [string]$pass, [string]$fail) {
    if ($ok) { $script:passes++; Write-Host "  [ OK ] $pass" } else { $script:fails++; Write-Host "  [FAIL] $fail" }
}
function Section([string]$t) { Write-Host ""; Write-Host "== $t ==" }
function Read-Text([string]$p) { return [IO.File]::ReadAllText($p) }
function Invoke-Installer([string]$Vault, [string]$Role, [string]$LabPath) {
    if ($IsWindows) {
        $ps1 = Join-Path $Bundle "Install_Heimdall.ps1"
        $text = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ps1 -Unattended -NoLaunch -SkipSoftware -VaultPath $Vault -Role $Role -LabPath $LabPath 2>&1 | Out-String
    } else {
        $sh = Join-Path $Bundle "install_heimdall.sh"
        $text = & bash $sh --unattended --no-launch --skip-software --vault $Vault --role $Role --lab-path $LabPath 2>&1 | Out-String
    }
    $code = $LASTEXITCODE
    if ($Console) { Add-Content -LiteralPath $Console -Value ("---- install $Role ----`n" + $text + "`nexit $code`n") }
    return @{ Code = $code; Text = $text }
}
$py = if ($IsWindows) { "python" } else { "python3" }
function Lab-Py([string[]]$ArgList) {
    $text = & $py -X utf8 @ArgList 2>&1 | Out-String
    return @{ Code = $LASTEXITCODE; Text = $text }
}
$kind = if ($IsWindows) { "junction" } else { "symlink" }
$shared = Join-Path $Work "lab_shared"; New-Item -ItemType Directory -Force $shared | Out-Null
$vA = Join-Path $Work "lab_vault_pi"; $vB = Join-Path $Work "lab_vault_grad"

Section "Install the pi vault and the grad vault linked to one shared folder"
$rA = Invoke-Installer $vA "pi" $shared
Check ($rA.Code -eq 0) "pi install exit 0" "pi install exit $($rA.Code)"
Check ($rA.Text.Contains("$kind; canary round trip passed")) "pi vault linked at install ($kind, canary passed)" "pi install did not report '$kind; canary round trip passed'"
$rB = Invoke-Installer $vB "grad" $shared
Check ($rB.Code -eq 0) "grad install exit 0" "grad install exit $($rB.Code)"
Check ($rB.Text.Contains("$kind; canary round trip passed")) "grad vault linked at install" "grad install did not report the canary round trip"
if ($rA.Code -ne 0 -or $rB.Code -ne 0) { Write-Host $rA.Text; Write-Host $rB.Text }

Section "Record, baseline and shared folder"
$recA = (Read-Text (Join-Path $vA "System/heimdall_install.json")) | ConvertFrom-Json
$recB = (Read-Text (Join-Path $vB "System/heimdall_install.json")) | ConvertFrom-Json
Check ("$($recA.role)" -eq "pi") "pi role recorded" "pi record role is '$($recA.role)'"
Check ("$($recB.role)" -eq "grad") "grad role recorded" "grad record role is '$($recB.role)'"
Check ("$($recA.lab_link.kind)" -eq $kind) "lab_link.kind is $kind" "lab_link.kind is '$($recA.lab_link.kind)'"
Check ("$($recA.lab_link.target)".Replace("\", "/").ToLower().EndsWith("lab_shared")) "lab_link.target is the shared folder" "lab_link.target is '$($recA.lab_link.target)'"
Check ($null -ne $recA.lab_link.checked_at) "lab_link.checked_at set" "lab_link.checked_at missing"
Check ((Read-Text (Join-Path $vA "System/health_baseline.md")).Contains("role:               pi")) "baseline carries the role" "baseline lacks 'role:               pi'"
$labItem = Get-Item -LiteralPath (Join-Path $vA "Lab") -Force
Check (($labItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) "Lab/ is a link, not a copy" "Lab/ is not a reparse point"
Check (@(Get-ChildItem -LiteralPath $vA -Directory -Filter "Lab.local_*").Count -eq 1) "old local Lab/ kept beside the link as Lab.local_<date>" "Lab.local_* count is not 1"
Check ((Test-Path -LiteralPath (Join-Path $shared "protocols/README.md")) -and (Test-Path -LiteralPath (Join-Path $shared "glossary.md"))) "scaffold carried into the shared folder" "shared folder lacks protocols/README.md or glossary.md"
Check (-not (Test-Path -LiteralPath (Join-Path $shared "roster.md"))) "no roster shipped" "roster.md shipped into the shared folder"
Check (@(Get-ChildItem -LiteralPath $shared -Force -Filter ".heimdall_canary_*").Count -eq 0) "canary cleaned up" "canary files left in the shared folder"
$settings = (Read-Text (Join-Path $vA ".claude/settings.json")) | ConvertFrom-Json
Check (($settings.permissions.deny -contains "Edit(./Lab/**)") -and ($settings.permissions.deny -contains "Write(./Lab/**)")) "settings.json denies Edit and Write on Lab/" "settings.json deny list lacks the Lab/ rules"

Section "Share a protocol from pi, read it from grad"
$share = Join-Path $vA "System/bin/share_to_lab.py"; $link = Join-Path $vA "System/bin/lab_link.py"
New-Item -ItemType Directory -Force (Join-Path $vA "Protocols") | Out-Null
[IO.File]::WriteAllText((Join-Path $vA "Protocols/lipid_extraction_v3.md"), "---`ntitle: Lipid extraction v3`nstatus: draft`nenergy: low`n---`n`n# Lipid extraction v3`n`n1. Weigh 50 mg tissue.`n2. Add 1 mL chloroform.`n")
$p = Lab-Py @($share, "--vault", $vA, "Protocols/lipid_extraction_v3.md", "--as", "Example Member")
Check ($p.Code -eq 10) "preview exits 10" "preview exit $($p.Code): $($p.Text)"
Check (-not (Test-Path -LiteralPath (Join-Path $shared "protocols/lipid_extraction_v3.md"))) "preview writes nothing" "preview wrote the file"
$p = Lab-Py @($share, "--vault", $vA, "Protocols/lipid_extraction_v3.md", "--as", "Example Member", "--yes")
Check ($p.Code -eq 0) "share exits 0" "share exit $($p.Code): $($p.Text)"
$landedPath = Join-Path $vB "Lab/protocols/lipid_extraction_v3.md"
$landed = if (Test-Path -LiteralPath $landedPath) { Read-Text $landedPath } else { "" }
Check ($landed.Contains("maintainer: Example Member")) "grad vault reads the shared protocol with its maintainer" "shared protocol not readable from the grad vault"
Check (-not $landed.Contains("energy:")) "personal fields stripped" "personal field 'energy:' leaked into the shared copy"

Section "Link check"
$p = Lab-Py @($link, "--vault", $vA, "check")
Check ($p.Code -eq 0) "lab_link check exits 0 while linked" "lab_link check exit $($p.Code): $($p.Text)"

# remove the links only, never the target
foreach ($v in @($vA, $vB)) { try { [IO.Directory]::Delete((Join-Path $v "Lab")) } catch { } }

Write-Host ""
Write-Host "lab layer rehearsal: $script:passes passed, $script:fails failed"
if ($env:GITHUB_STEP_SUMMARY) { Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value "Lab layer rehearsal ($kind): $script:passes passed, $script:fails failed" }
if ($script:fails -gt 0) { exit 1 }
