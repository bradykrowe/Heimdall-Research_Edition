<#
    CI helper: record a sha256 for every file under the given roots, or compare
    two such records. Used by .github/workflows/install.yml to prove that a
    second installer run changes nothing outside the expected files.

    snapshot.ps1 -Paths <root>[,<root>...] -Out <file>
    snapshot.ps1 -Compare -Before <file> -After <file> [-Allow <relative path>[,...]]

    Record lines are "<root>TAB<relative path>TAB<sha256>", sorted. __pycache__
    folders are skipped: Python may write them on import and they prove nothing.
#>
[CmdletBinding()]
param(
    [string[]]$Paths = @(),
    [string]$Out = "",
    [switch]$Compare,
    [string]$Before = "",
    [string]$After = "",
    [string[]]$Allow = @()
)

$ErrorActionPreference = "Stop"

function Read-Record {
    param([string]$Path)
    $map = @{}
    foreach ($line in Get-Content -LiteralPath $Path) {
        if (-not $line) { continue }
        $parts = $line -split "`t"
        if ($parts.Count -lt 3) { continue }
        $map["$($parts[0])`t$($parts[1])"] = $parts[2]
    }
    return $map
}

if ($Compare) {
    if (-not $Before -or -not $After) { throw "Compare needs -Before and -After." }
    $b = Read-Record $Before
    $a = Read-Record $After
    $changes = @()
    foreach ($k in $a.Keys) {
        if (-not $b.ContainsKey($k)) { $changes += [pscustomobject]@{ kind = "added";   key = $k } }
        elseif ($b[$k] -ne $a[$k])  { $changes += [pscustomobject]@{ kind = "changed"; key = $k } }
    }
    foreach ($k in $b.Keys) {
        if (-not $a.ContainsKey($k)) { $changes += [pscustomobject]@{ kind = "removed"; key = $k } }
    }
    $bad = @()
    foreach ($c in $changes | Sort-Object key) {
        $rel = ($c.key -split "`t")[1]
        $allowed = $false
        foreach ($pattern in $Allow) { if ($rel -like $pattern) { $allowed = $true } }
        $tag = "NOT EXPECTED"
        if ($allowed) { $tag = "expected" }
        Write-Host ("  {0,-8} {1}  ({2})" -f $c.kind, $c.key.Replace("`t", "  "), $tag)
        if (-not $allowed) { $bad += $c }
    }
    Write-Host ("Second run: {0} change(s), {1} outside the expected files." -f $changes.Count, $bad.Count)
    if ($bad.Count -gt 0) { exit 1 }
    exit 0
}

if (-not $Out) { throw "Snapshot needs -Out." }
$lines = New-Object System.Collections.Generic.List[string]
foreach ($root in $Paths) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    $item = Get-Item -LiteralPath $root -Force
    if ($item.PSIsContainer) {
        $base = $item.FullName.TrimEnd("\", "/")
        Get-ChildItem -LiteralPath $base -Recurse -File -Force | ForEach-Object {
            if ($_.FullName -match "__pycache__") { return }
            $rel = $_.FullName.Substring($base.Length).TrimStart("\", "/").Replace("\", "/")
            $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
            $lines.Add("$base`t$rel`t$hash")
        }
    } else {
        $hash = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash
        $lines.Add("$($item.FullName)`t.`t$hash")
    }
}
$sorted = $lines | Sort-Object
Set-Content -LiteralPath $Out -Value $sorted -Encoding utf8
Write-Host ("Snapshot: {0} file(s) recorded to {1}" -f $sorted.Count, $Out)
