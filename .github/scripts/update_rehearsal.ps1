# Update rehearsal (M3b). Installs a vault from the Release bundle without the
# software step, patches a copy of the bundle into an "upstream v2" with a new
# TAG, runs the update twice and the rollback twice, and checks the contract
# the suites check: an edited file keeps the edit with a .new beside it, an
# untouched file is replaced, a new file is added, Lab/, System/secrets/ and
# .obsidian/ are byte-identical throughout, and rollback restores the record.
#
# Runs under pwsh on macOS and Windows. The installer is bash on macOS and
# Windows PowerShell on Windows, the same files the lab runs.
param(
    [Parameter(Mandatory)][string]$Bundle,   # unpacked bundle root (holds install_heimdall.sh)
    [Parameter(Mandatory)][string]$Vault,    # vault to create
    [Parameter(Mandatory)][string]$Work,     # scratch folder for the v2 bundle
    [string]$Console = ""                    # where to tee installer output
)
$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false
$script:fails = 0; $script:passes = 0
function Check([bool]$ok, [string]$pass, [string]$fail) {
    if ($ok) { $script:passes++; Write-Host "  [ OK ] $pass" } else { $script:fails++; Write-Host "  [FAIL] $fail" }
}
function Section([string]$t) { Write-Host ""; Write-Host "== $t ==" }
function Read-Text([string]$p) { return [IO.File]::ReadAllText($p) }
function Hash([string]$p) { return (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLower() }
function TreeHash([string]$root) {
    if (-not (Test-Path -LiteralPath $root)) { return "absent" }
    $lines = Get-ChildItem -LiteralPath $root -Recurse -File -Force | Sort-Object FullName | ForEach-Object {
        $rel = $_.FullName.Substring($root.Length).TrimStart("\", "/").Replace("\", "/")
        "$rel $(Hash $_.FullName)"
    }
    return ($lines -join "`n")
}
function Invoke-Installer([string]$BundleDir, [string[]]$Extra) {
    $sep = "---- installer run: $($Extra -join ' ') ----"
    if ($IsWindows) {
        $ps1 = Join-Path $BundleDir "Install_Heimdall.ps1"
        $argv = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $ps1, "-Unattended", "-NoLaunch", "-SkipSoftware", "-VaultPath", $Vault) + $Extra
        $text = & powershell.exe @argv 2>&1 | Out-String
    } else {
        $sh = Join-Path $BundleDir "install_heimdall.sh"
        $argv = @($sh, "--unattended", "--no-launch", "--skip-software", "--vault", $Vault) + $Extra
        $text = & bash @argv 2>&1 | Out-String
    }
    $code = $LASTEXITCODE
    if ($Console) { Add-Content -LiteralPath $Console -Value ($sep + "`n" + $text + "`nexit $code`n") }
    return @{ Code = $code; Text = $text }
}
function Record() { return (Read-Text (Join-Path $Vault "System/heimdall_install.json")) | ConvertFrom-Json }

# ------------------------------------------------------------ fresh install ----
Section "Fresh install from the Release bundle (software step skipped)"
$r0 = Invoke-Installer $Bundle @()
Check ($r0.Code -eq 0) "installer exit 0" "installer exit $($r0.Code)"
Check (-not $r0.Text.Contains("[fail]")) "no [fail] line" "installer printed a [fail] line"
$recPath = Join-Path $Vault "System/heimdall_install.json"
Check (Test-Path -LiteralPath $recPath) "install record written" "no install record at $recPath"
if (-not (Test-Path -LiteralPath $recPath)) { Write-Host $r0.Text; exit 1 }
$rec0 = Record
$tag0 = "$($rec0.tag)"
$fileCount = @($rec0.files.PSObject.Properties).Count
Check ($fileCount -gt 100) "record files map has $fileCount entries" "record files map has only $fileCount entries"
Check ($rec0.files."START_HERE.md" -eq (Hash (Join-Path $Vault "START_HERE.md"))) "record hash matches START_HERE.md on disk" "record hash differs from START_HERE.md on disk"

# every manifest line matches the installed file (sha256sum -c from the vault root)
$manifest = Join-Path $Bundle "manifest/framework.sha256"
$bad = 0; $n = 0
foreach ($line in (Get-Content -LiteralPath $manifest)) {
    if ($line -notmatch "^([0-9a-f]{64})  (.+)$") { continue }
    $n++
    $p = Join-Path $Vault $Matches[2]
    if (-not (Test-Path -LiteralPath $p) -or (Hash $p) -ne $Matches[1]) { $bad++; Write-Host "       mismatch: $($Matches[2])" }
}
Check ($bad -eq 0) "all $n manifest entries match the installed files" "$bad of $n manifest entries do not match"

# ------------------------------------------------------------- local state ----
Section "Local edits and protected trees"
[IO.File]::AppendAllText((Join-Path $Vault "START_HERE.md"), "`nmy local edit`n")
New-Item -ItemType Directory -Force (Join-Path $Vault "Projects") | Out-Null
[IO.File]::WriteAllText((Join-Path $Vault "Projects/mine.md"), "personal note`n")
[IO.File]::WriteAllText((Join-Path $Vault "Lab/README.md"), "lab note edited by the lab`n")
$labTree = TreeHash (Join-Path $Vault "Lab")
$secretsTree = TreeHash (Join-Path $Vault "System/secrets")
$obsidianTree = TreeHash (Join-Path $Vault ".obsidian")
$mineHash = Hash (Join-Path $Vault "Projects/mine.md")

# -------------------------------------------------------------- upstream v2 ----
Section "Build the upstream v2 bundle"
$b2 = Join-Path $Work "bundle_v2"
if (Test-Path -LiteralPath $b2) { Remove-Item -LiteralPath $b2 -Recurse -Force }
Copy-Item -LiteralPath $Bundle -Destination $b2 -Recurse
$newTag = "$tag0-ci2"
[IO.File]::AppendAllText((Join-Path $b2 "payload/vault/START_HERE.md"), "`nupstream v2 line`n")
[IO.File]::AppendAllText((Join-Path $b2 "payload/vault/System/edition_floors.md"), "`nupstream v2 floor`n")
[IO.File]::AppendAllText((Join-Path $b2 "payload/vault/Lab/README.md"), "`nmust never land in a linked lab folder`n")
[IO.File]::AppendAllText((Join-Path $b2 "payload/vault/System/secrets/obsidian.env"), "`n# must never land`n")
[IO.File]::WriteAllText((Join-Path $b2 "payload/claude/commands/ci_newcmd.md"), "# new command`n")
[IO.File]::WriteAllText((Join-Path $b2 "TAG"), "$newTag`n")
# regenerate the manifest: same paths, fresh hashes, plus the new command
$out = New-Object System.Collections.Generic.List[string]
foreach ($line in (Get-Content -LiteralPath (Join-Path $b2 "manifest/framework.sha256"))) {
    if ($line -notmatch "^[0-9a-f]{64}  (.+)$") { continue }
    $rel = $Matches[1]
    $src = if ($rel.StartsWith(".claude/")) { Join-Path $b2 ("payload/claude/" + $rel.Substring(8)) } else { Join-Path $b2 ("payload/vault/" + $rel) }
    if (Test-Path -LiteralPath $src) { $out.Add("$(Hash $src)  $rel") }
}
$out.Add("$(Hash (Join-Path $b2 'payload/claude/commands/ci_newcmd.md'))  .claude/commands/ci_newcmd.md")
[IO.File]::WriteAllText((Join-Path $b2 "manifest/framework.sha256"), (($out | Sort-Object { $_.Substring(66) }) -join "`n") + "`n")
Check ((Get-Content -LiteralPath (Join-Path $b2 "manifest/framework.sha256")).Count -eq ($n + 1)) "v2 manifest has $($n + 1) lines" "v2 manifest line count is off"

# ------------------------------------------------------------------- update ----
Section "Update to $newTag"
$upd = if ($IsWindows) { @("-Update") } else { @("--update") }
$r1 = Invoke-Installer $b2 $upd
Check ($r1.Code -eq 0) "update exit 0" "update exit $($r1.Code)"
Check ($r1.Text.Contains("Replaced 1 unchanged file(s)")) "edition_floors.md replaced (1 unchanged file)" "expected 'Replaced 1 unchanged file(s)'"
Check ($r1.Text.Contains("Kept 1 file(s) you edited")) "START_HERE.md kept (1 edited file)" "expected 'Kept 1 file(s) you edited'"
Check ($r1.Text.Contains("Added 1 new file(s)")) "ci_newcmd.md added" "expected 'Added 1 new file(s)'"
Check ((Read-Text (Join-Path $Vault "START_HERE.md")).Contains("my local edit")) "START_HERE.md keeps the local edit" "local edit lost"
Check ((Test-Path -LiteralPath (Join-Path $Vault "START_HERE.md.new")) -and (Read-Text (Join-Path $Vault "START_HERE.md.new")).Contains("upstream v2 line")) "START_HERE.md.new holds upstream" "START_HERE.md.new missing or not upstream"
Check ((Read-Text (Join-Path $Vault "System/edition_floors.md")).Contains("upstream v2 floor")) "edition_floors.md replaced" "edition_floors.md not replaced"
Check (Test-Path -LiteralPath (Join-Path $Vault ".claude/commands/ci_newcmd.md")) "new command added" "new command missing"
Check ($labTree -eq (TreeHash (Join-Path $Vault "Lab"))) "Lab/ byte-identical after update" "Lab/ changed during update"
Check ($secretsTree -eq (TreeHash (Join-Path $Vault "System/secrets"))) "System/secrets/ byte-identical after update" "System/secrets/ changed during update"
Check ($obsidianTree -eq (TreeHash (Join-Path $Vault ".obsidian"))) ".obsidian/ byte-identical after update" ".obsidian/ changed during update"
Check ($mineHash -eq (Hash (Join-Path $Vault "Projects/mine.md"))) "personal file untouched" "personal file changed"
$rec1 = Record
Check ("$($rec1.tag)" -eq $newTag) "record tag is $newTag" "record tag is $($rec1.tag)"
# read the raw text: ConvertFrom-Json turns ISO stamps into DateTime objects
$rawRec = Read-Text $recPath
Check ($rawRec -match '"updated_at":\s*"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z"') "updated_at is UTC and ends in Z" "updated_at in the record is not an ISO UTC stamp ending in Z"
Check ("$($rec1.installed_at)" -eq "$($rec0.installed_at)") "installed_at kept" "installed_at changed"
Check ($null -ne $rec1.files.".claude/commands/ci_newcmd.md") "files map follows the new manifest" "files map lacks the new command"
$snaps = @(Get-ChildItem -LiteralPath (Join-Path $Vault "System/.heimdall_backup") -Directory)
Check ($snaps.Count -eq 1 -and $snaps[0].Name.StartsWith("${newTag}_")) "one snapshot named ${newTag}_<stamp>" "snapshots: $($snaps.Name -join ', ')"
Check ($snaps.Count -ge 1 -and (Test-Path -LiteralPath (Join-Path $snaps[0].FullName "START_HERE.md"))) "snapshot holds the pre-update START_HERE.md" "snapshot lacks START_HERE.md"

Section "Second update from the same bundle"
$r2 = Invoke-Installer $b2 $upd
Check ($r2.Code -eq 0) "second update exit 0" "second update exit $($r2.Code)"
Check ($r2.Text.Contains("Replaced 0 unchanged file(s)")) "nothing to replace the second time" "expected 'Replaced 0 unchanged file(s)'"
Check ($r2.Text.Contains("Kept 1 file(s) you edited")) "edited file still kept" "expected 'Kept 1 file(s) you edited'"

# ----------------------------------------------------------------- rollback ----
Section "Rollback twice"
$rb = if ($IsWindows) { @("-Rollback") } else { @("--rollback") }
$r3 = Invoke-Installer $b2 $rb
Check ($r3.Code -eq 0) "first rollback exit 0" "first rollback exit $($r3.Code)"
Check ("$((Record).tag)" -eq $newTag) "first rollback restores the second update's snapshot (tag still $newTag)" "tag after first rollback: $((Record).tag)"
$r4 = Invoke-Installer $b2 $rb
Check ($r4.Code -eq 0) "second rollback exit 0" "second rollback exit $($r4.Code)"
$rec3 = Record
Check ("$($rec3.tag)" -eq $tag0) "record tag back to $tag0" "record tag is $($rec3.tag)"
Check (-not (Test-Path -LiteralPath (Join-Path $Vault "START_HERE.md.new"))) ".new removed" ".new still present"
Check (-not (Test-Path -LiteralPath (Join-Path $Vault ".claude/commands/ci_newcmd.md"))) "added file removed" "added file still present"
Check (-not (Read-Text (Join-Path $Vault "System/edition_floors.md")).Contains("upstream v2 floor")) "replaced file restored" "edition_floors.md still upstream"
Check ((Read-Text (Join-Path $Vault "START_HERE.md")).Contains("my local edit")) "local edit survives the rollback" "local edit lost in rollback"
Check ($labTree -eq (TreeHash (Join-Path $Vault "Lab"))) "Lab/ byte-identical after rollback" "Lab/ changed during rollback"
Check ($secretsTree -eq (TreeHash (Join-Path $Vault "System/secrets"))) "System/secrets/ byte-identical after rollback" "System/secrets/ changed during rollback"
Check ($obsidianTree -eq (TreeHash (Join-Path $Vault ".obsidian"))) ".obsidian/ byte-identical after rollback" ".obsidian/ changed during rollback"

Write-Host ""
Write-Host "update rehearsal: $script:passes passed, $script:fails failed"
if ($env:GITHUB_STEP_SUMMARY) { Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value "Update rehearsal ($([Environment]::OSVersion.Platform)): $script:passes passed, $script:fails failed" }
if ($script:fails -gt 0) { foreach ($r in @($r0, $r1, $r3)) { if ($r.Code -ne 0) { Write-Host $r.Text } }; exit 1 }
