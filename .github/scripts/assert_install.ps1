<#
    CI helper: check what the installer left behind. Runs under pwsh on the
    macOS and Windows runners (.github/workflows/install.yml).

    assert_install.ps1 -Vault <vault> -Unpack <unpacked bundle folder>
                       -Log <install_log.txt> -Console <captured installer output>
                       [-Phase first|second]

    Expected counts are never literals. They come, in this order, from
    manifest/framework.sha256 in the bundle, from MIN_COMMANDS and MIN_SKILLS
    in edition.env in the bundle, or, until the build ships either, from the
    payload inside the bundle itself.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Vault,
    [Parameter(Mandatory = $true)][string]$Unpack,
    [Parameter(Mandatory = $true)][string]$Log,
    [Parameter(Mandatory = $true)][string]$Console,
    [ValidateSet("first", "second")][string]$Phase = "first"
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false
$script:failures = @()
$script:passes = 0

function Ok   { param([string]$m) Write-Host "  [ ok ] $m"; $script:passes++ }
function Fail { param([string]$m) Write-Host "  [FAIL] $m"; $script:failures += $m }
function Check {
    param([bool]$Condition, [string]$OkMessage, [string]$FailMessage)
    if ($Condition) { Ok $OkMessage } else { Fail $FailMessage }
}
function Section { param([string]$m) Write-Host ""; Write-Host "== $m ==" }

$onMac = $IsMacOS
$onWin = $IsWindows

# ----------------------------------------------------------------- counts ----
Section "Expected counts"
function Get-ExpectedCounts {
    $fw = Join-Path $Unpack "manifest/framework.sha256"
    $ed = Join-Path $Unpack "edition.env"
    if (Test-Path -LiteralPath $fw) {
        $lines = Get-Content -LiteralPath $fw
        $cmd = @($lines | Where-Object { $_ -match "claude/commands/[^/]+\.md" }).Count
        $sk  = @($lines | Where-Object { $_ -match "claude/skills/[^/]+/SKILL\.md" }).Count
        return @{ source = "manifest/framework.sha256"; commands = $cmd; skills = $sk; exact = $true }
    }
    if (Test-Path -LiteralPath $ed) {
        $m = Select-String -LiteralPath $ed -Pattern "^MIN_COMMANDS=(\d+)" | Select-Object -First 1
        $s = Select-String -LiteralPath $ed -Pattern "^MIN_SKILLS=(\d+)" | Select-Object -First 1
        if ($m) {
            $skills = 0
            if ($s) { $skills = [int]$s.Matches[0].Groups[1].Value }
            return @{ source = "edition.env"; commands = [int]$m.Matches[0].Groups[1].Value; skills = $skills; exact = $false }
        }
    }
    $cmd = @(Get-ChildItem -LiteralPath (Join-Path $Unpack "payload/claude/commands") -Filter *.md -File).Count
    $sk  = @(Get-ChildItem -LiteralPath (Join-Path $Unpack "payload/claude/skills") -Directory).Count
    return @{ source = "payload inside the bundle (no manifest shipped yet)"; commands = $cmd; skills = $sk; exact = $true }
}
$expected = Get-ExpectedCounts
Write-Host "  source: $($expected.source)"
Write-Host "  commands: $($expected.commands)  skills: $($expected.skills)  exact: $($expected.exact)"
Check ($expected.commands -gt 0) "expected command count is positive" "expected command count is 0; the bundle carries no commands or the manifest is unreadable"
Check ($expected.skills -gt 0)   "expected skill count is positive"   "expected skill count is 0; the bundle carries no skills or the manifest is unreadable"

# ------------------------------------------------------------- vault files ----
Section "Vault files"
Check (Test-Path -LiteralPath $Vault) "vault exists at $Vault" "vault missing at $Vault"
foreach ($f in @("CLAUDE.md", "START_HERE.md", "System/health_baseline.md", "System/secrets/obsidian.env", "System/bin/obsidian_mcp.py", ".claude/settings.json", ".mcp.json", ".obsidian/community-plugins.json")) {
    Check (Test-Path -LiteralPath (Join-Path $Vault $f)) "$f present" "$f missing"
}

# ------------------------------------------------------ commands and skills ----
Section "Commands and skills"
$cmdDir = Join-Path $Vault ".claude/commands"
$skDir  = Join-Path $Vault ".claude/skills"
$gotCmd = 0; $gotSk = 0
if (Test-Path -LiteralPath $cmdDir) { $gotCmd = @(Get-ChildItem -LiteralPath $cmdDir -Filter *.md -File).Count }
if (Test-Path -LiteralPath $skDir)  { $gotSk  = @(Get-ChildItem -LiteralPath $skDir -Directory).Count }
Write-Host "  installed commands: $gotCmd  skills: $gotSk"
if ($expected.exact) {
    Check ($gotCmd -eq $expected.commands) "command count $gotCmd matches the bundle" "command count $gotCmd, expected $($expected.commands)"
    Check ($gotSk -eq $expected.skills)    "skill count $gotSk matches the bundle"    "skill count $gotSk, expected $($expected.skills)"
} else {
    Check ($gotCmd -ge $expected.commands) "command count $gotCmd meets the minimum" "command count $gotCmd below the minimum $($expected.commands)"
    Check ($gotSk -ge $expected.skills)    "skill count $gotSk meets the minimum"    "skill count $gotSk below the minimum $($expected.skills)"
}
Check ($gotCmd -gt 0) "at least one command installed" "no commands installed"
Check ($gotSk -gt 0)  "at least one skill installed"   "no skills installed"

# ----------------------------------------------------------------- plugins ----
Section "Obsidian plugins"
$manifestPath = Join-Path $Unpack "manifest/plugins.json"
$wantPlugins = @()
if (Test-Path -LiteralPath $manifestPath) {
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $wantPlugins = @($manifest.core | ForEach-Object { $_.id }) + @($manifest.recommended | ForEach-Object { $_.id })
}
Check ($wantPlugins.Count -gt 0) "manifest lists $($wantPlugins.Count) plugin(s) for the default tier" "manifest/plugins.json missing or empty"
$cpPath = Join-Path $Vault ".obsidian/community-plugins.json"
$enabled = @()
if (Test-Path -LiteralPath $cpPath) {
    try { $enabled = @(Get-Content -LiteralPath $cpPath -Raw | ConvertFrom-Json) } catch { Fail "community-plugins.json does not parse: $_" }
}
Write-Host "  enabled: $($enabled -join ', ')"
Check ($enabled.Count -gt 0) "$($enabled.Count) plugin(s) enabled" "no plugins enabled"
foreach ($id in $wantPlugins) {
    $main = Join-Path $Vault ".obsidian/plugins/$id/main.js"
    Check (($enabled -contains $id) -and (Test-Path -LiteralPath $main)) "plugin $id enabled and on disk" "plugin $id not enabled or main.js missing"
}

# --------------------------------------------------------------- connector ----
Section "Obsidian connector"
$venvPy = ""
try {
    $mcp = Get-Content -LiteralPath (Join-Path $Vault ".mcp.json") -Raw | ConvertFrom-Json
    $venvPy = [string]$mcp.mcpServers.obsidian.command
    $launcherArg = [string]$mcp.mcpServers.obsidian.args[0]
    Ok ".mcp.json parses; command $venvPy"
    Check (Test-Path -LiteralPath $venvPy) "connector python exists" "connector python missing at $venvPy"
    Check (Test-Path -LiteralPath $launcherArg) "launcher path in .mcp.json exists" "launcher path in .mcp.json missing: $launcherArg"
    if ($onMac) { Check ($venvPy -like "*/.heimdall/obsidian_mcp/bin/python*") "venv lives in ~/.heimdall/obsidian_mcp" "venv path unexpected: $venvPy" }
    if ($onWin) { Check ($venvPy -like "*\Heimdall\obsidian_mcp\Scripts\python.exe") "venv lives in LOCALAPPDATA\Heimdall\obsidian_mcp" "venv path unexpected: $venvPy" }
} catch { Fail ".mcp.json unreadable: $_" }

if ($venvPy -and (Test-Path -LiteralPath $venvPy)) {
    $imp = & $venvPy -c "import importlib.util; print(importlib.util.find_spec('mcp_obsidian') is not None)" 2>&1 | Select-Object -First 1
    Check ("$imp" -eq "True") "mcp_obsidian importable from the venv" "mcp_obsidian not importable from the venv ($imp)"

    $envFile  = Join-Path $Vault "System/secrets/obsidian.env"
    $launcher = Join-Path $Vault "System/bin/obsidian_mcp.py"
    $orig = Get-Content -LiteralPath $envFile -Raw
    & $venvPy $launcher --check 2>&1 | Out-Null
    $blank = $LASTEXITCODE
    Check ($blank -eq 2) "connector check exits 2 with a blank key" "connector check exited $blank with a blank key, expected 2"

    $dummy = $orig -replace "(?m)^OBSIDIAN_API_KEY=.*$", "OBSIDIAN_API_KEY=ci-dummy-key-not-a-real-key"
    [IO.File]::WriteAllText($envFile, $dummy)
    try {
        $out = & $venvPy $launcher --check 2>&1 | Out-String
        $code = $LASTEXITCODE
        Write-Host "  check output: $($out.Trim())"
        Check ($code -eq 0) "connector check exits 0 with a dummy key (server imports)" "connector check exited $code with a dummy key, expected 0"
    } finally {
        [IO.File]::WriteAllText($envFile, $orig)
    }
}

# ------------------------------------------------------------- per OS bits ----
if ($onMac) {
    Section "macOS software"
    $profiles = @(".zprofile", ".bash_profile", ".zshrc", ".bashrc", ".profile") | ForEach-Object { Join-Path $HOME $_ } | Where-Object { Test-Path -LiteralPath $_ }
    $n = 0
    foreach ($p in $profiles) { $n += @(Select-String -LiteralPath $p -Pattern "brew shellenv").Count }
    Check ($n -eq 1) "Homebrew PATH line written once across the shell profiles" "Homebrew PATH line found $n time(s) across the shell profiles, expected 1"
    Check (Test-Path -LiteralPath "/opt/homebrew/bin/brew") "brew at /opt/homebrew/bin/brew" "brew missing at /opt/homebrew/bin/brew"
    Check (Test-Path -LiteralPath "/opt/homebrew/opt/python@3.12/bin/python3.12") "python@3.12 keg path present" "python@3.12 keg path missing"
    foreach ($b in @("node", "npm", "claude")) { Check (Test-Path -LiteralPath "/opt/homebrew/bin/$b") "$b at /opt/homebrew/bin/$b" "$b missing at /opt/homebrew/bin/$b" }
    Check (Test-Path -LiteralPath "/Applications/Obsidian.app") "Obsidian.app present" "Obsidian.app missing"
    Check (Test-Path -LiteralPath (Join-Path $Vault "start_heimdall.command")) "start_heimdall.command present" "start_heimdall.command missing"
}
if ($onWin) {
    Section "Windows software"
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
    foreach ($c in @("node", "npm", "python", "claude")) {
        $g = Get-Command $c -ErrorAction SilentlyContinue
        Check ($null -ne $g) "$c on PATH at $($g.Source)" "$c not found on the registry PATH"
    }
    $pv = ""
    try { $pv = & python -c "import sys; print(sys.version_info[0]*100+sys.version_info[1])" 2>&1 | Select-Object -First 1 } catch { }
    Check ("$pv" -match "^\d+$" -and [int]$pv -ge 311) "python reports 3.11 or newer ($pv)" "python version probe failed or too old ($pv)"
    $obs = @((Join-Path $env:LOCALAPPDATA "Obsidian\Obsidian.exe"), (Join-Path $env:ProgramFiles "Obsidian\Obsidian.exe"), (Join-Path $env:LOCALAPPDATA "Programs\Obsidian\Obsidian.exe")) | Where-Object { Test-Path -LiteralPath $_ }
    if ($obs) { Ok "Obsidian.exe at $($obs[0])" } else { Write-Host "  [warn] Obsidian.exe not found in the usual places (installer only warns about this)" }
    Check (Test-Path -LiteralPath (Join-Path $Vault "Start_Heimdall.cmd")) "Start_Heimdall.cmd present" "Start_Heimdall.cmd missing"
}

# ------------------------------------------------------------ log, summary ----
Section "Install log and summary"
Check (Test-Path -LiteralPath $Log) "install log present" "install log missing at $Log"
if (Test-Path -LiteralPath $Log) {
    $failLines = @(Select-String -LiteralPath $Log -Pattern "\[fail\]")
    Check ($failLines.Count -eq 0) "no [fail] lines in the install log" "install log has $($failLines.Count) [fail] line(s): $($failLines | ForEach-Object { $_.Line } | Select-Object -First 3 | Out-String)"
    $finished = @(Select-String -LiteralPath $Log -Pattern "install finished")
    Check ($finished.Count -ge 1) "install log records a finish" "install log never records a finish"
}
Check ((Test-Path -LiteralPath $Console) -and ((Get-Content -LiteralPath $Console -Raw) -match "HEIMDALL INSTALL SUMMARY")) "summary printed" "summary block not found in the installer output"

# ------------------------------------------------------------------ result ----
Write-Host ""
$summary = "assert_install ($Phase run): $script:passes passed, $($script:failures.Count) failed."
Write-Host $summary
if ($env:GITHUB_STEP_SUMMARY) {
    Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value "### $summary"
    Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value "Counts from: $($expected.source). Commands $gotCmd of $($expected.commands), skills $gotSk of $($expected.skills), plugins enabled $($enabled.Count)."
    foreach ($f in $script:failures) { Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value "- FAIL: $f" }
}
if ($script:failures.Count -gt 0) { exit 1 }
exit 0
