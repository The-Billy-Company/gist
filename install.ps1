#!/usr/bin/env pwsh
<#
.SYNOPSIS
Build and install gist, relate and irregex on Windows.

.DESCRIPTION
The Windows counterpart of `zig build`, and it has to be a script of its
own rather than a line in a Makefile because there is no `make` here and the two
POSIX installers (`shell/install.sh`, `editor/install.sh`) are bash. Same four
jobs, in the same order: build the binaries, put them somewhere already on PATH,
place the generated manual/completions and the editor plugin where each installed
tool already looks, then index the tree.

Three things genuinely differ from the POSIX path, and each one is a Windows fact
rather than a preference:

  * A symlink needs a privilege here (Developer Mode, or an elevated shell), so
    every placement TRIES a link and falls back to a copy. The link is worth
    trying because it is what makes `git pull` refresh an install site for free;
    the copy is worth having because refusing to install over a missing privilege
    would be worse than a placement you have to re-run.
  * A running image cannot be overwritten, but it CAN be renamed. So replacing a
    binary while a resident daemon holds it moves the old one aside first, rather
    than failing with a sharing violation halfway through an install.
  * PowerShell has no autoloaded completion directory the way bash, zsh and fish
    do — its only such place is your profile. So the profile gets one guarded
    line (`-NoProfileEdit` declines), where the POSIX script can just drop a file
    and say nothing.

Idempotent: re-run it to refresh after a rebuild. Nothing here needs elevation.

.PARAMETER Prefix
Where the three binaries are placed. Default `%LOCALAPPDATA%\Programs\gist` — the
per-user location Windows itself uses for user-scope installs: no elevation, and
not roamed to other machines the way `%APPDATA%` is.

.PARAMETER NoIndex
Skip the trailing `gist index`. The binaries still work — an unindexed query
answers from a correct live scan, just slower.

.PARAMETER NoProfileEdit
Leave `$PROFILE` alone. Completions are still placed, and the line to dot-source
them is printed for you to add.

.PARAMETER NoEditor
Skip the Vim/Neovim plugin. Equivalent to `GIST_VIM_INSTALL=0`.

.PARAMETER NoShell
Skip the manual and completions. Equivalent to `GIST_SHELL_INSTALL=0`.

.EXAMPLE
.\install.ps1
.EXAMPLE
.\install.ps1 -Prefix C:\tools\bin -NoProfileEdit
#>
[CmdletBinding()]
param(
    [string] $Prefix = (Join-Path $env:LOCALAPPDATA 'Programs\gist'),
    [switch] $NoIndex,
    [switch] $NoProfileEdit,
    [switch] $NoEditor,
    [switch] $NoShell
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
$binaries = @('gist', 'relate', 'irregex')

function Write-Note { param([string] $Message) Write-Host "$([char]0x2713)  $Message" -ForegroundColor Green }
function Write-Warn { param([string] $Message) Write-Host "!  $Message" -ForegroundColor Yellow }

# Place `Source` at `Destination` as a link if this session may create one, else
# as a copy. Returns 'link', 'copy', or $null — the caller reports which, because
# a copy goes stale on the next rebuild and a link does not, and that is a
# difference worth telling the person who ran this.
function Place-Artifact {
    param([Parameter(Mandatory)] [string] $Source, [Parameter(Mandatory)] $Destination)

    $parent = Split-Path -Parent $Destination
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }

    # An existing link (or a stale copy) is replaced; an existing REAL directory
    # someone else populated is not, mirroring `editor/install.sh`.
    $existing = Get-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
    if ($existing) {
        $isLink = $null -ne $existing.LinkType
        if (-not $isLink -and $existing.PSIsContainer) {
            Write-Warn "$Destination exists and is not a link - leaving it alone"
            return $null
        }
        if (-not (Remove-Placed $Destination)) { return $null }
    }

    try {
        New-Item -ItemType SymbolicLink -Path $Destination -Target $Source -ErrorAction Stop | Out-Null
        return 'link'
    } catch {
        # No SeCreateSymbolicLinkPrivilege (Developer Mode off, shell not
        # elevated). Expected on a default install, so it is a fallback and not a
        # warning.
        try {
            Copy-Item -LiteralPath $Source -Destination $Destination -Recurse -Force -ErrorAction Stop
            return 'copy'
        } catch {
            Write-Warn "could not place $Destination : $($_.Exception.Message)"
            return $null
        }
    }
}

# Get `Path` out of the way. A plain delete is enough for anything unmapped; a
# binary a resident daemon is still running refuses to be deleted but WILL be
# renamed, which is the whole reason this is a function.
function Remove-Placed {
    param([Parameter(Mandatory)] [string] $Path)
    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        return $true
    } catch {
        $aside = "$Path.old-$(Get-Random -Maximum 100000)"
        try {
            Move-Item -LiteralPath $Path -Destination $aside -Force -ErrorAction Stop
            # Best-effort: it stays until the process holding it exits, and the
            # next run sweeps it.
            Remove-Item -LiteralPath $aside -Force -ErrorAction SilentlyContinue
            return $true
        } catch {
            Write-Warn "$Path is in use and could not be moved aside - stop the daemon (gist serve) and re-run"
            return $false
        }
    }
}

# ── build ────────────────────────────────────────────────────────────────
$zig = Get-Command zig -ErrorAction SilentlyContinue
if (-not $zig) {
    Write-Warn "zig not installed - install Zig 0.16 (this repo pins it in .mise.toml); skipping gist"
    exit 0
}
Write-Host "building gist + relate + irregex..."
# From the package root rather than through `--build-file`, so `zig-out` lands
# where every other entry point expects it and a caller's own directory cannot
# change what gets built.
Push-Location $root
try {
    & $zig.Source build
    if ($LASTEXITCODE -ne 0) { throw "zig build failed" }
} finally { Pop-Location }

$out = Join-Path $root 'zig-out'
$share = Join-Path $out 'share'

# ── binaries ─────────────────────────────────────────────────────────────
# Swept first: a previous run may have left one behind because a daemon still
# held it, and a stale image on PATH is worse than a missing one.
Get-ChildItem -Path $Prefix -Filter '*.old-*' -Force -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue

foreach ($name in $binaries) {
    $source = Join-Path $out "bin\$name.exe"
    if (-not (Test-Path -LiteralPath $source)) { throw "$source missing after build" }
    $how = Place-Artifact -Source $source -Destination (Join-Path $Prefix "$name.exe")
    if ($how) { Write-Note "$name.exe -> $Prefix ($how)" }
}

# ── PATH ─────────────────────────────────────────────────────────────────
# User scope, so no elevation and no effect on anyone else on the box. .NET
# broadcasts WM_SETTINGCHANGE on write, so new shells see it; this session is
# updated by hand because its own block was copied at launch.
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$onPath = ($userPath -split ';' | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') }) -contains $Prefix.TrimEnd('\')
if (-not $onPath) {
    $joined = if ([string]::IsNullOrEmpty($userPath)) { $Prefix } else { "$($userPath.TrimEnd(';'));$Prefix" }
    [Environment]::SetEnvironmentVariable('Path', $joined, 'User')
    Write-Note "added $Prefix to your user PATH (new terminals pick it up)"
}
if (($env:Path -split ';' | ForEach-Object { $_.TrimEnd('\') }) -notcontains $Prefix.TrimEnd('\')) {
    $env:Path = "$env:Path;$Prefix"
}

# The installed image, not the build output: if this cannot run, the install did
# not happen and every step below would be describing a binary nobody has.
$gist = Join-Path $Prefix 'gist.exe'
if (-not (Test-Path -LiteralPath $gist)) { throw "gist.exe was not placed at $Prefix" }

# Mint one generated artifact, or fail loudly. A partial write here is the worst
# outcome available: a truncated completion still parses often enough to get
# dot-sourced from a profile and then misbehave at every prompt.
function Write-Generated {
    param([Parameter(Mandatory)] [string] $Kind, [Parameter(Mandatory)] [string] $Destination)
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
    $text = & $gist --generate $Kind
    if ($LASTEXITCODE -ne 0) { throw "gist --generate $Kind exited $LASTEXITCODE" }
    Set-Content -LiteralPath $Destination -Value $text -Encoding utf8
}

# ── manual + completions ─────────────────────────────────────────────────
# Minted by `gist --generate` from the same flag table argv is parsed with, so
# there is no second description of the CLI to drift.
if (-not $NoShell -and $env:GIST_SHELL_INSTALL -ne '0') {
    $completion = Join-Path $share 'powershell\gist.ps1'
    Write-Generated -Kind 'complete-powershell' -Destination $completion

    $placed = Join-Path $env:LOCALAPPDATA 'gist\gist.ps1'
    if (Place-Artifact -Source $completion -Destination $placed) {
        Write-Note "pwsh: completion -> $placed"
        $line = ". `"$placed`""
        if ($NoProfileEdit) {
            Write-Warn "  add to `$PROFILE: $line"
        } elseif ((Test-Path -LiteralPath $PROFILE) -and (Select-String -LiteralPath $PROFILE -SimpleMatch $placed -Quiet)) {
            Write-Note "  already sourced from your `$PROFILE"
        } else {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $PROFILE) | Out-Null
            Add-Content -LiteralPath $PROFILE -Value @('', '# gist completions (placed by irregex install.ps1)', $line)
            Write-Note "  sourced from your `$PROFILE - open a new terminal to use it"
        }
    }

    # The manual too, for whoever has a man that reads it (Git for Windows, MSYS2,
    # WSL sharing the home directory). Placed rather than asserted: nothing on a
    # stock Windows will read it, and it costs one file.
    $man = Join-Path $share 'man\man1\gist.1'
    Write-Generated -Kind 'man' -Destination $man
    Write-Note "man: gist(1) -> $man"
}

# ── editor plugin ────────────────────────────────────────────────────────
# Vim 8 and Neovim both load every directory under `pack/*/start/` with no
# configuration; the package roots simply have different names here than on
# POSIX (`vimfiles`, and nvim's `%LOCALAPPDATA%\nvim-data`).
if (-not $NoEditor -and $env:GIST_VIM_INSTALL -ne '0') {
    $plugin = Join-Path $root 'editor\vim'
    $editors = @(
        @{ Exe = 'vim'; Pack = (Join-Path $HOME 'vimfiles\pack\gist\start'); Args = @('-es', '-u', 'NONE', '-i', 'NONE') }
        @{ Exe = 'nvim'; Pack = (Join-Path $env:LOCALAPPDATA 'nvim-data\site\pack\gist\start'); Args = @('--headless', '-u', 'NONE', '-i', 'NONE') }
    )
    foreach ($editor in $editors) {
        $exe = Get-Command $editor.Exe -ErrorAction SilentlyContinue
        if (-not $exe) { continue }
        $dest = Join-Path $editor.Pack 'gist'
        $how = Place-Artifact -Source $plugin -Destination $dest
        if (-not $how) { continue }
        & $exe.Source @($editor.Args) -c "helptags $(Join-Path $dest 'doc')" -c 'qall!' 2>&1 | Out-Null
        Write-Note "$($editor.Exe): gist plugin -> $dest ($how) - :help gist"
    }
}

# ── index ────────────────────────────────────────────────────────────────
# What the tree is (roots, skips, extra types) belongs in a committed
# `.irregex.toml` at its root, so it is the same corpus on every clone and every
# platform - this installer deliberately knows nothing tree-specific.
if (-not $NoIndex) {
    & $gist index
    if ($LASTEXITCODE -ne 0) { throw "gist index exited $LASTEXITCODE" }
    & $gist status
}
