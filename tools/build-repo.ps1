<#
.SYNOPSIS
    Builds all CloudStream plugin modules and assembles the repository metadata.

.DESCRIPTION
    Pipeline:
      1. (unless -SkipBuild) runs `gradlew make makePluginsJson` to compile every
         module into a .cs3 package and generate module metadata (build/plugins.json)
      2. copies every freshly built *.cs3 into ./builds
      3. merges module metadata with the static imported entries (tools/imported-plugins.json)
      4. rewrites all URLs from tools/repo-config.json
      5. recomputes fileSize + fileHash (sha256) from the actual files in ./builds
      6. writes ./plugins.json and ./repo.json

    The script fails hard on: gradle failure, missing package file,
    or duplicate internalName - so the repo can never ship inconsistent metadata.

.EXAMPLE
    powershell -File tools\build-repo.ps1            # full build + assemble
    pwsh -File tools/build-repo.ps1 -SkipBuild       # re-assemble only
#>
[CmdletBinding()]
param(
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'

$toolsDir  = $PSScriptRoot
$root      = Split-Path -Parent $toolsDir
$buildsDir = Join-Path $root 'builds'

function Get-Sha256([string]$Path) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $fs  = [System.IO.File]::OpenRead($Path)
    try { $hash = $sha.ComputeHash($fs) } finally { $fs.Close() }
    return ([System.BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
}

# Reads a JSON file containing an array and always returns a flat object[].
# Handles the PS5.1 quirk where ConvertFrom-Json emits the whole array as one item.
function Read-JsonArray([string]$Path) {
    $parsed = Get-Content $Path -Raw | ConvertFrom-Json
    $items  = @()
    if ($parsed -is [System.Array]) {
        foreach ($x in $parsed) { $items += $x }
    } elseif ($null -ne $parsed) {
        $items += $parsed
    }
    return $items
}


# ---------------------------------------------------------------- 1. build
if (-not $SkipBuild) {
    $isWindowsHost = ($env:OS -eq 'Windows_NT')
    $gradlew = if ($isWindowsHost) { Join-Path $root 'gradlew.bat' } else { Join-Path $root 'gradlew' }
    if (-not (Test-Path $gradlew)) { throw "Gradle wrapper not found: $gradlew" }
    Write-Host "==> Building all plugin modules (gradlew make makePluginsJson)..."
    Push-Location $root
    try {
        & $gradlew make makePluginsJson --console=plain
        if ($LASTEXITCODE -ne 0) { throw "Gradle build failed with exit code $LASTEXITCODE" }
    } finally {
        Pop-Location
    }
}

# ------------------------------------------------- 2. copy built packages
New-Item -ItemType Directory -Force -Path $buildsDir | Out-Null
$skipDirs = @('builds', 'tools', 'gradle', 'local-repo')
$copied = 0
foreach ($dir in Get-ChildItem $root -Directory) {
    if (($skipDirs -contains $dir.Name) -or $dir.Name.StartsWith('.')) { continue }
    $pkgDir = Join-Path $dir.FullName 'build'
    if (Test-Path $pkgDir) {
        foreach ($f in Get-ChildItem $pkgDir -Filter '*.cs3') {
            Copy-Item $f.FullName $buildsDir -Force
            $copied++
        }
    }
}
Write-Host "==> Copied $copied freshly built package(s) into builds/"

# ------------------------------------------------------- 3. load metadata
$moduleMeta = Join-Path (Join-Path $root 'build') 'plugins.json'
if (-not (Test-Path $moduleMeta)) {
    throw "Missing $moduleMeta - run without -SkipBuild first (gradlew make makePluginsJson)"
}
$entries = Read-JsonArray $moduleMeta

$importedMeta = Join-Path $toolsDir 'imported-plugins.json'
if (Test-Path $importedMeta) {
    $imported = Read-JsonArray $importedMeta
    $entries += $imported
    Write-Host "==> Merged $($imported.Count) imported binary plugin entry(ies)"
}

# ------------------------------------------------------- 4. repo config
$configPath = Join-Path $toolsDir 'repo-config.json'
$repoBase   = 'https://raw.githubusercontent.com/YOUR_GITHUB_USERNAME/CloudStreamRepo/main'
$repoUrl    = 'https://github.com/YOUR_GITHUB_USERNAME/CloudStreamRepo'
$repoName   = 'CloudStreamRepo'
$repoDesc   = 'Combined stable CloudStream providers'
if (Test-Path $configPath) {
    $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
    if ($cfg.repoBase)    { $repoBase = $cfg.repoBase }
    if ($cfg.repoUrl)     { $repoUrl  = $cfg.repoUrl }
    if ($cfg.name)        { $repoName = $cfg.name }
    if ($cfg.description) { $repoDesc = $cfg.description }
} else {
    Write-Warning "tools/repo-config.json not found - using placeholder URLs"
}
$repoBase = $repoBase.TrimEnd('/')

# ------------------------------------- 5. normalize entries + verify files
$shaCache = @{}
$seen     = @{}
$normalized = foreach ($e in $entries) {
    $valid = ($e -is [System.Management.Automation.PSCustomObject]) -and
             $e.name -and $e.internalName -and ($e.url -is [string])
    if (-not $valid) {
        throw "Malformed entry (missing name/internalName/url): $($e | ConvertTo-Json -Depth 5)"
    }

    # file name = last segment of the original url (preserves spaces etc.)
    $rawName  = $e.url.Substring($e.url.LastIndexOf('/') + 1)
    $fileName = [uri]::UnescapeDataString($rawName)
    $file     = Join-Path $buildsDir $fileName
    if (-not (Test-Path $file)) {
        throw "Missing package for '$($e.name)' - expected builds\$fileName"
    }

    $key = $e.internalName.ToLowerInvariant()
    if ($seen.ContainsKey($key)) { throw "Duplicate internalName '$($e.internalName)'" }
    $seen[$key] = $true

    if (-not $shaCache.ContainsKey($file)) { $shaCache[$file] = Get-Sha256 $file }
    $e.url           = "$repoBase/builds/$fileName"
    $e.repositoryUrl = $repoUrl
    $e.fileSize      = [int](Get-Item $file).Length
    $e.fileHash      = 'sha256-' + $shaCache[$file]
    $e
}
$normalized = @($normalized | Sort-Object { $_.name.ToLowerInvariant() })

# ------------------------------------------------- 6. write repo metadata
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$pluginsPath = Join-Path $root 'plugins.json'
$pluginsJson = ConvertTo-Json -InputObject $normalized -Depth 10
[System.IO.File]::WriteAllText($pluginsPath, $pluginsJson, $utf8NoBom)

$repo = [ordered]@{
    name            = $repoName
    description     = $repoDesc
    manifestVersion = 1
    repositoryUrl   = $repoUrl
    pluginLists     = @("$repoBase/plugins.json")
}
$repoPath = Join-Path $root 'repo.json'
$repoJson = ConvertTo-Json -InputObject $repo -Depth 5
[System.IO.File]::WriteAllText($repoPath, $repoJson, $utf8NoBom)

Write-Host ''
Write-Host "==> Repository assembled: $($normalized.Count) plugins"
Write-Host "    $pluginsPath"
Write-Host "    $repoPath"
Write-Host ''
$normalized | Select-Object name, version, status, language | Format-Table -AutoSize

if ($repoBase -like '*YOUR_GITHUB_USERNAME*') {
    Write-Warning 'repo-config.json still contains the YOUR_GITHUB_USERNAME placeholder - edit tools/repo-config.json before publishing.'
}

