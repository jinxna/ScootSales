param([Parameter(Mandatory = $true)][string]$Worktree)
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$full = (Resolve-Path $Worktree).Path

function Normalize([string]$Path) { ([IO.Path]::GetFullPath($Path) -replace "/", "\").TrimEnd("\").ToLowerInvariant() }

$listed = @(git -C $repo worktree list --porcelain | Where-Object { $_ -like "worktree *" } | ForEach-Object { Normalize $_.Substring(9) })
if ($listed.Count -eq 0) { Write-Error "git worktree list failed; nothing changed"; exit 1 }
$target = Normalize $full
if ($target -eq $listed[0]) { Write-Error "$full is the main working tree; nothing changed"; exit 1 }
if ($listed -notcontains $target) { Write-Error "$full is not a linked worktree of this repository; nothing changed"; exit 1 }

function Find-Links([string]$Folder) {
    foreach ($child in Get-ChildItem -LiteralPath $Folder -Directory -Force -ErrorAction SilentlyContinue) {
        if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) { $child } else { Find-Links $child.FullName }
    }
}

foreach ($link in @(Find-Links $full)) {
    cmd /c rmdir "`"$($link.FullName)`""
    if (Test-Path -LiteralPath $link.FullName) { throw "Could not unlink $($link.FullName); worktree not removed" }
    Write-Output "unlinked $($link.FullName)"
}
if (@(Find-Links $full).Count -gt 0) { throw "Links remain under $full; worktree not removed" }
git -C $repo worktree remove --force $full
if ($LASTEXITCODE -ne 0) { Write-Error "git worktree remove failed with exit code $LASTEXITCODE; worktree not removed"; exit $LASTEXITCODE }
Write-Output "removed $full"
