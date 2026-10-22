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
    [switch]$SkipBuild,
    # Skip the upstream liveness probes (useful offline / on air-gapped builds).
    [switch]$SkipHealthCheck,
    # Turn unhealthy upstreams into a hard build failure instead of a warning.
    # Off by default: a third-party site being down should not block a release.
    [switch]$FailOnUnhealthy
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

# ---------------------------------------------------------------- health check
# Probes the upstream sites the plugins depend on, so domain rot is caught at
# build time instead of by users.
#
# These mirror sites rotate domains often (net52 -> net77 -> a dead net50), and
# they answer an app-gate page with HTTP 200. A status-only check would call
# that healthy, so every check also asserts on the response body.
function Test-UpstreamHealth {
    param(
        [string]$ConfigPath,
        [switch]$FailOnUnhealthy
    )

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        Write-Host "==> Health check skipped (no $(Split-Path -Leaf $ConfigPath))"
        return $true
    }

    try {
        $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    } catch {
        Write-Warning "Could not parse $(Split-Path -Leaf $ConfigPath): $($_.Exception.Message)"
        return $true
    }
    $checks = @($cfg.checks)
    if ($checks.Count -eq 0) {
        Write-Host '==> Health check skipped (no checks configured)'
        return $true
    }

    $timeout = if ($cfg.timeoutSeconds) { [int]$cfg.timeoutSeconds } else { 20 }
    $ua = if ($cfg.userAgent) { [string]$cfg.userAgent } else { 'CloudStreamRepo-healthcheck/1.0' }

    Add-Type -AssemblyName System.Net.Http
    $handler = New-Object System.Net.Http.HttpClientHandler
    # A redirect to a dead host is a failure, not a pass - do not follow it.
    $handler.AllowAutoRedirect = $false
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($timeout)
    [void]$client.DefaultRequestHeaders.TryAddWithoutValidation('User-Agent', $ua)

    $results = @()
    foreach ($c in $checks) {
        $status = 'OK'
        $detail = ''
        try {
            $req = New-Object System.Net.Http.HttpRequestMessage
            $req.Method = [System.Net.Http.HttpMethod]::Get
            $req.RequestUri = [string]$c.url
            $resp = $client.SendAsync($req).Result
            $body = $resp.Content.ReadAsStringAsync().Result
            $code = [int]$resp.StatusCode

            $expected = if ($null -ne $c.status) { [int]$c.status } else { 200 }
            if ($code -ge 300 -and $code -lt 400) {
                $loc = if ($resp.Headers.Location) { $resp.Headers.Location } else { '(no Location)' }
                $status = 'DEAD'
                $detail = "HTTP $code redirect -> $loc"
            } elseif ($code -ne $expected) {
                $status = 'DEAD'
                $detail = "HTTP $code (expected $expected)"
            } else {
                foreach ($bad in @($c.notContains)) {
                    if ($bad -and $body -like "*$bad*") {
                        $status = 'GATED'
                        $detail = "served '$bad'"
                        break
                    }
                }
                if ($status -eq 'OK') {
                    foreach ($good in (@($c.contains) | Where-Object { $_ })) {
                        if ($body -notlike "*$good*") {
                            $status = 'BROKEN'
                            $detail = "body missing '$good'"
                            break
                        }
                    }
                }
            }
        } catch {
            $status = 'UNREACHABLE'
            $detail = $_.Exception.GetBaseException().Message
        }
        $results += [pscustomobject]@{
            Check  = [string]$c.name
            Status = $status
            Detail = $detail
        }
    }
    $client.Dispose()

    $bad = @($results | Where-Object { $_.Status -ne 'OK' })
    Write-Host ''
    Write-Host "==> Upstream health: $($results.Count - $bad.Count)/$($results.Count) healthy"
    $results | Format-Table -AutoSize | Out-String | Write-Host

    if ($bad.Count -gt 0) {
        Write-Warning "$($bad.Count) upstream endpoint(s) are not serving normal content."
        Write-Warning 'Plugins are still built and published; users of the affected providers'
        Write-Warning 'will see errors. If the domain changed upstream, update the URL inside the'
        Write-Warning 'plugin and adjust tools/domain-health.json.'
        if ($FailOnUnhealthy) {
            throw "Health check failed for $($bad.Count) endpoint(s)."
        }
    }
    return ($bad.Count -eq 0)
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

# Serialises to JSON in a DETERMINISTIC way.
# PowerShell 5.1 and 7+ disagree on ConvertTo-Json output:
#   * 5.1 indents 4 spaces per level, 7+ uses 2
#   * 5.1 pads object keys with two spaces after the colon ("k":  v), 7+ one
#   * 5.1 indents array elements far deeper than 7+ does
#   * 5.1 escapes '&' as & (and '<'/'>'), 7+ writes them literally
# Left unnormalised, the same input produces different bytes on different hosts,
# so every CI run rewrites plugins.json/repo.json and creates a pointless commit
# (which then re-triggers the build).
# Rather than post-processing text (fragile), we render the object graph
# ourselves with a fixed 2-space style that matches PowerShell 7 exactly.
function ConvertTo-CanonicalJson($InputObject, [int]$Depth, [int]$Indent = 0) {
    if ($InputObject -is [string] -or $InputObject -is [bool] -or
        $InputObject -is [int] -or $InputObject -is [long] -or
        $InputObject -is [double] -or $InputObject -is [decimal]) {
        $scalar = ConvertTo-Json -InputObject $InputObject -Compress
        # PS 5.1 escapes these as < while PS 7 emits them literally.
        # Undo that so both editions produce identical bytes.
        $scalar = $scalar -replace '\\u0026', '&' -replace '\\u003c', '<' -replace '\\u003e', '>'
        return $scalar
    }
    if ($null -eq $InputObject) { return 'null' }

    $pad  = ' ' * $Indent
    $pad2 = ' ' * ($Indent + 2)
    $isDict = $InputObject -is [System.Collections.IDictionary] -or
              ($InputObject.PSObject.Properties.Name -contains 'Keys')
    $isList = $InputObject -is [System.Collections.IEnumerable] -and -not $isDict

    $sb = New-Object System.Text.StringBuilder

    if ($isDict) {
        $pairs = @()
        foreach ($k in $InputObject.Keys) { $pairs += ,@($k, $InputObject[$k]) }
        if ($pairs.Count -eq 0) { return '{}' }
        [void]$sb.Append('{')
        for ($i = 0; $i -lt $pairs.Count; $i++) {
            [void]$sb.Append("`n$pad2")
            [void]$sb.Append((ConvertTo-CanonicalJson ([string]$pairs[$i][0]) 0))
            [void]$sb.Append(': ')
            [void]$sb.Append((ConvertTo-CanonicalJson $pairs[$i][1] $Depth ($Indent + 2)))
            if ($i -lt $pairs.Count - 1) { [void]$sb.Append(',') }
        }
        [void]$sb.Append("`n$pad}")
        return $sb.ToString()
    }

    if ($isList) {
        $items = @($InputObject)
        if ($items.Count -eq 0) { return '[]' }
        [void]$sb.Append('[')
        for ($i = 0; $i -lt $items.Count; $i++) {
            [void]$sb.Append("`n$pad2")
            [void]$sb.Append((ConvertTo-CanonicalJson $items[$i] $Depth ($Indent + 2)))
            if ($i -lt $items.Count - 1) { [void]$sb.Append(',') }
        }
        [void]$sb.Append("`n$pad]")
        return $sb.ToString()
    }

    # Plain object with NoteProperties (what ConvertFrom-Json produces).
    $props = @($InputObject.PSObject.Properties | Where-Object { $_.MemberType -eq 'NoteProperty' })
    if ($props.Count -eq 0) { return '{}' }
    [void]$sb.Append('{')
    for ($i = 0; $i -lt $props.Count; $i++) {
        [void]$sb.Append("`n$pad2")
        [void]$sb.Append((ConvertTo-CanonicalJson $props[$i].Name 0))
        [void]$sb.Append(': ')
        [void]$sb.Append((ConvertTo-CanonicalJson $props[$i].Value $Depth ($Indent + 2)))
        if ($i -lt $props.Count - 1) { [void]$sb.Append(',') }
    }
    [void]$sb.Append("`n$pad}")
    return $sb.ToString()
}


# ---------------------------------------------------------------- api pin check
# The CloudStream gradle plugin downloads its API jar from the MOVING
# "pre-release" GitHub release asset, so two builds of identical source embed
# different debug metadata in classes.dex. Every .cs3 then gets a new fileHash
# and CloudStream re-downloads all plugins for no functional change.
#
# build.gradle.kts points urlPrefix at the vendored copy in
# local-repo/cloudstream-api, which makes builds reproducible. This check makes
# that pin trustworthy: if the vendored jar is replaced or corrupted without the
# lock file being updated, the build stops here instead of silently shipping 30
# changed binaries.
function Test-CloudstreamApiPin {
    param([string]$Root)

    $lockPath = Join-Path (Join-Path $Root 'tools') 'cloudstream-api.lock.json'
    if (-not (Test-Path -LiteralPath $lockPath)) {
        Write-Warning 'cloudstream-api.lock.json not found - the pinned CloudStream API jar cannot be verified.'
        return $true
    }
    try {
        $lock = Get-Content $lockPath -Raw | ConvertFrom-Json
    } catch {
        throw "Could not parse cloudstream-api.lock.json: $($_.Exception.Message)"
    }

    $jar = Join-Path $Root ([string]$lock.vendorPath)
    if (-not (Test-Path -LiteralPath $jar)) {
        throw "Pinned CloudStream API jar is missing: $jar`n" +
              "Download it from $($lock.sourceUrl) and save it to that path, or delete" +
              ' local-repo/cloudstream-api to fall back to the unpinned download.'
    }

    $actualHash = Get-Sha256 $jar
    $actualSize = (Get-Item -LiteralPath $jar).Length
    if ($actualHash -ne ([string]$lock.sha256).ToLowerInvariant()) {
        throw "Pinned CloudStream API jar does not match tools/cloudstream-api.lock.json.`n" +
              "  expected sha256 $($lock.sha256)`n" +
              "  actual   sha256 $actualHash`n" +
              'This is what causes phantom plugin updates. Either restore the pinned jar' +
              ' or update the lock file deliberately (and bump module versions).'
    }
    if ($null -ne $lock.size -and $actualSize -ne [int64]$lock.size) {
        throw "Pinned CloudStream API jar size mismatch: expected $($lock.size), got $actualSize"
    }

    Write-Host "==> CloudStream API pinned: $([string]$lock.apiVersionName) (sha256 $($actualHash.Substring(0,12)))"
    return $true
}

# ---------------------------------------------------------------- 1. build
if (-not $SkipBuild) {
    $null = Test-CloudstreamApiPin -Root $root
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

# ------------------------------- 2a. snapshot current published hashes FIRST
# The drift report below compares the package that is live in builds/ against
# the one the build just produced, so the old hashes must be read before the
# copy overwrites them - otherwise every file always looks unchanged.
$publishedHash = @{}
foreach ($f in Get-ChildItem $buildsDir -Filter '*.cs3' -ErrorAction SilentlyContinue) {
    $publishedHash[$f.Name] = Get-Sha256 $f.FullName
}

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

# ------------------------------- 2b. reproducibility / drift report
# The .cs3 packaging is deterministic (entry timestamps are pinned) and the
# CloudStream API jar is now vendored + verified, so rebuilding unchanged source
# MUST reproduce byte-identical output. A changed hash therefore means source
# really did change, or the API jar pin moved - it is no longer routine.
# Surfacing which plugins changed - and whether their declared version was
# bumped - makes that visible instead of silently shipping 36 re-downloads.
$changedWithoutVersionBump = @()
foreach ($dir in Get-ChildItem $root -Directory) {
    if ($skipDirs -contains $dir.Name -or $dir.Name.StartsWith('.')) { continue }
    $pkgDir = Join-Path $dir.FullName 'build'
    if (-not (Test-Path $pkgDir)) { continue }
    $gradleFile = Join-Path $dir.FullName 'build.gradle.kts'
    foreach ($f in Get-ChildItem $pkgDir -Filter '*.cs3') {
        if (-not $publishedHash.ContainsKey($f.Name)) { continue }
        $oldHash = $publishedHash[$f.Name]
        $newHash = Get-Sha256 $f.FullName
        if ($oldHash -eq $newHash) { continue }
        $declared = $null
        if (Test-Path $gradleFile) {
            $m = Select-String -Path $gradleFile -Pattern '^\s*version\s*=\s*(\d+)' |
                 Select-Object -First 1
            if ($m) { $declared = [int]$m.Matches[0].Groups[1].Value }
        }
        $changedWithoutVersionBump += [pscustomobject]@{
            Plugin  = $dir.Name
            Version = $(if ($null -ne $declared) { $declared } else { '?' })
            NewHash = $newHash.Substring(0, 12)
        }
    }
}
if ($changedWithoutVersionBump.Count -gt 0) {
    Write-Host ''
    Write-Warning "==> $($changedWithoutVersionBump.Count) plugin(s) produced a different binary. CloudStream re-downloads a plugin whenever its fileHash changes, so bump 'version' in the module's build.gradle.kts if the change is intentional:"
    $changedWithoutVersionBump | Format-Table -AutoSize | Out-String | Write-Host
    Write-Warning '   Rebuilds are reproducible: if you edited no source and no version changed, the API jar pin in tools/cloudstream-api.lock.json was altered.'
}

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
$pluginsJson = ConvertTo-CanonicalJson $normalized 10
[System.IO.File]::WriteAllText($pluginsPath, $pluginsJson, $utf8NoBom)

$repo = [ordered]@{
    name            = $repoName
    description     = $repoDesc
    manifestVersion = 1
    repositoryUrl   = $repoUrl
    pluginLists     = @("$repoBase/plugins.json")
}
$repoPath = Join-Path $root 'repo.json'
$repoJson = ConvertTo-CanonicalJson $repo 5
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

# ------------------------------------------------------ 7. upstream liveness
# Runs last so it never blocks metadata assembly: we always want a valid,
# hash-consistent plugins.json even when a third-party site is down.
if ($SkipHealthCheck) {
    Write-Host ''
    Write-Host '==> Upstream health check skipped (-SkipHealthCheck)'
} else {
    $null = Test-UpstreamHealth -ConfigPath (Join-Path $toolsDir 'domain-health.json') -FailOnUnhealthy:$FailOnUnhealthy
}

