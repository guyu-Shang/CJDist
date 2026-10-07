param([string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot))

$ErrorActionPreference = 'Stop'
$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)
$OwnedRoot = [IO.Path]::GetFullPath((Join-Path $ProjectRoot '.cjdist'))
$TestRoot = [IO.Path]::GetFullPath((Join-Path $OwnedRoot 'removal-safety-tests'))
$ToolSource = Join-Path $ProjectRoot 'dist\MyApp'
$ProbeRoot = Join-Path $TestRoot 'probe'
$DriverRoot = Join-Path $TestRoot 'driver'
$ExternalRoot = Join-Path $TestRoot 'external-target'
$Output = Join-Path $ProbeRoot 'dist\RemovalSafety'
$Link = Join-Path $Output 'linked-outside'

if ([IO.Path]::GetDirectoryName($TestRoot) -ne $OwnedRoot) {
    throw 'Unsafe removal-safety test root.'
}

function Remove-TestRoot {
    if (Test-Path -LiteralPath $Link) {
        $item = Get-Item -Force -LiteralPath $Link
        if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Expected test reparse point: $Link"
        }
        Remove-Item -LiteralPath $Link -Force
    }
    if (Test-Path -LiteralPath $TestRoot) {
        $item = Get-Item -Force -LiteralPath $TestRoot
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Refusing to recursively remove reparse test root: $TestRoot"
        }
        Remove-Item -LiteralPath $TestRoot -Recurse -Force
    }
}

Remove-TestRoot
New-Item -ItemType Directory -Path (Join-Path $ProbeRoot 'src'),$DriverRoot,$ExternalRoot -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $ToolSource 'main.exe') -Destination (Join-Path $DriverRoot 'cjdist.exe')
Copy-Item -LiteralPath (Join-Path $ToolSource 'libcangjie-runtime.dll') -Destination $DriverRoot
Copy-Item -LiteralPath (Join-Path $ToolSource 'libboundscheck.dll') -Destination $DriverRoot

$source = @'
package probe

main(): Int64 {
    println("removal safety probe")
    return 0
}
'@
$project = @'
[package]
  cjc-version = "1.0.5"
  name = "probe"
  version = "0.1.0"
  output-type = "executable"
  compile-option = ""
  override-compile-option = ""
  link-option = ""
  package-configuration = {}

[dependencies]
'@
$config = @'
[dist]
name = "RemovalSafety"
entry = "target/release/bin/main.exe"
output-dir = "dist/RemovalSafety"

[dist.runtime]
mode = "dynamic"
source = "build-sdk"

[dist.files]
include = []
dlls = []
licenses = []

[dist.verify]
args = []
expected-exit-code = 0
timeout-ms = 5000
working-directory = "package-root"
'@
[IO.File]::WriteAllText((Join-Path $ProbeRoot 'src\main.cj'), $source, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $ProbeRoot 'cjpm.toml'), $project, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $ProbeRoot 'cjdist.toml'), $config, [Text.UTF8Encoding]::new($false))

try {
    Push-Location $ProbeRoot
    try {
        & (Join-Path $DriverRoot 'cjdist.exe') build 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'Unable to create the baseline probe distribution.' }
        [IO.File]::WriteAllText((Join-Path $ExternalRoot 'sentinel.txt'), 'must-survive', [Text.UTF8Encoding]::new($false))
        New-Item -ItemType Junction -Path $Link -Target $ExternalRoot | Out-Null

        $diagnostic = & (Join-Path $DriverRoot 'cjdist.exe') build 2>&1 | Out-String
        $code = $LASTEXITCODE
        $diagnostic | Write-Host
        if ($code -ne 5) { throw "Unsafe existing output returned $code instead of 5." }
        if ($diagnostic -notmatch 'unsafe filesystem tree|reparse point') {
            throw 'Missing recursive-removal safety diagnostic.'
        }
        if (-not (Test-Path -LiteralPath $Link)) { throw 'CJDist unexpectedly removed the test junction.' }
        if ([IO.File]::ReadAllText((Join-Path $ExternalRoot 'sentinel.txt')) -ne 'must-survive') {
            throw 'External junction target was changed.'
        }
        Write-Host 'PASS recursive-removal-refuses-internal-junction-and-preserves-target'
    } finally {
        Pop-Location
    }
} finally {
    Remove-TestRoot
}
exit 0
