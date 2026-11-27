param(
    [string]$Moon,
    [string]$Python = 'python',
    [switch]$Offline,
    [switch]$Test,
    [string]$TargetDir
)

$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$originalMoonHome = $env:MOON_HOME
$originalMoonWork = $env:MOON_WORK

if (!$Moon) {
    $command = Get-Command moon -ErrorAction SilentlyContinue
    if (!$command) {
        throw 'MoonBit toolchain missing. Put moon on PATH or pass -Moon with its absolute path.'
    }
    $Moon = $command.Source
}
$Moon = (Get-Command $Moon -ErrorAction Stop).Source
$toolRoot = Split-Path -Parent (Split-Path -Parent $Moon)
if (!$TargetDir) { $TargetDir = Join-Path $project '_build' }
$TargetDir = [IO.Path]::GetFullPath($TargetDir)

Push-Location -LiteralPath $project
try {
    $helper = Join-Path $PSScriptRoot 'pin-mooncakes.py'
    if ($Offline) { & $Python $helper --offline } else { & $Python $helper }
    if ($LASTEXITCODE -ne 0) { throw 'Could not prepare pinned Mooncakes dependencies.' }
    if (Test-Path -LiteralPath (Join-Path $toolRoot 'lib/core')) {
        $env:MOON_HOME = $toolRoot
    }
    $env:MOON_WORK = Join-Path $project '.work/moon.work'
    if ($Test) {
        & $Moon test --target js --frozen --target-dir $TargetDir -p WeiR-h/pdftextguard
        if ($LASTEXITCODE -ne 0) { throw 'MoonBit tests failed.' }
    }
    & $Moon build --target js --release --frozen --target-dir $TargetDir 'cmd/pdftextguard'
    if ($LASTEXITCODE -ne 0) { throw 'MoonBit build failed.' }

    $artifact = Join-Path $TargetDir 'js/release/build/WeiR-h/pdftextguard/cmd/pdftextguard/pdftextguard.js'
    $manifest = Get-Content -Raw -LiteralPath (Join-Path $project 'moon.mod')
    if ($manifest -notmatch '(?m)^version = "([0-9.]+)"$') { throw 'Missing module version.' }
    $version = "v$($Matches[1])"
    $actual = & node $artifact --version
    if ($LASTEXITCODE -ne 0 -or $actual -ne "PDFTextGuard $version") {
        throw 'Built CLI version does not match moon.mod.'
    }
    $dist = Join-Path $project 'dist'
    New-Item -ItemType Directory -Path $dist -Force | Out-Null
    $filename = "pdftextguard-$version.cjs"
    $entry = Join-Path $dist $filename
    [IO.File]::WriteAllBytes($entry, [IO.File]::ReadAllBytes($artifact))
    foreach ($document in @('LICENSE', 'THIRD_PARTY.md', 'LICENSE-APACHE-2.0', 'LICENSE-MOONBIT-CORE-NOTICE')) {
        [IO.File]::WriteAllBytes((Join-Path $dist $document), [IO.File]::ReadAllBytes((Join-Path $project $document)))
    }
    $digest = (Get-FileHash -Algorithm SHA256 -LiteralPath $entry).Hash.ToLowerInvariant()
    "$digest  $filename" | Set-Content -LiteralPath (Join-Path $dist 'SHA256SUMS') -Encoding utf8NoBOM
    Write-Output $entry
} finally {
    $env:MOON_HOME = $originalMoonHome
    $env:MOON_WORK = $originalMoonWork
    Pop-Location
}
