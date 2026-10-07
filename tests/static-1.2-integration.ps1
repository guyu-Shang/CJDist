param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot),
    [Parameter(Mandatory = $true)]
    [string]$SdkRoot
)
$ErrorActionPreference = 'Stop'
$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)
$Tool = Join-Path $ProjectRoot 'dist\MyApp\main.exe'
$Root = [IO.Path]::GetFullPath((Join-Path $ProjectRoot '.cjdist\static-1.2-tests'))
if (-not (Test-Path -LiteralPath (Join-Path $SdkRoot 'envsetup.ps1'))) { throw "Cangjie 1.2 SDK not found: $SdkRoot" }
if ([IO.Path]::GetDirectoryName($Root) -ne [IO.Path]::GetFullPath((Join-Path $ProjectRoot '.cjdist'))) { throw 'Unsafe static test root.' }
if (Test-Path -LiteralPath $Root) { Remove-Item -LiteralPath $Root -Recurse -Force }
New-Item -ItemType Directory -Path (Join-Path $Root 'probe\src') -Force | Out-Null
$source = @'
package probe

main(): Int64 {
    println("Cangjie 1.2 static integration OK")
    return 0
}
'@
[IO.File]::WriteAllText((Join-Path $Root 'probe\src\main.cj'), $source, [Text.UTF8Encoding]::new($false))
$staticProject = @'
[package]
  cjc-version = "1.2.0"
  name = "probe"
  version = "0.1.0"
  output-type = "executable"
  compile-option = "--static"
  override-compile-option = ""
  link-option = ""
  package-configuration = {}

[dependencies]
'@
$distConfig = @'
[dist]
name = "Static Integration"
entry = "target/release/bin/main.exe"
output-dir = "dist/StaticIntegration"

[dist.runtime]
mode = "static"
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
[IO.File]::WriteAllText((Join-Path $Root 'probe\cjpm.toml'), $staticProject, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $Root 'probe\cjdist.toml'), $distConfig, [Text.UTF8Encoding]::new($false))
try {
    . (Join-Path $SdkRoot 'envsetup.ps1')
    Push-Location (Join-Path $Root 'probe')
    try {
        & $Tool build; if ($LASTEXITCODE -ne 0) { throw 'Static CJDist build failed.' }
        & $Tool verify '.\dist\StaticIntegration'; if ($LASTEXITCODE -ne 0) { throw 'Static standalone verify failed.' }
        $output = Join-Path (Get-Location) 'dist\StaticIntegration'
        if (Test-Path (Join-Path $output 'libcangjie-runtime.dll')) { throw 'Static output contains libcangjie-runtime.dll.' }
        if (Test-Path (Join-Path $output 'libboundscheck.dll')) { throw 'Static output contains libboundscheck.dll.' }
        $manifest = Get-Content -Raw (Join-Path $output 'cjdist-manifest.json') | ConvertFrom-Json
        if ($manifest.runtime.mode -ne 'static') { throw 'Static manifest mode mismatch.' }
        Write-Host 'PASS cangjie-1.2-static-build-no-runtime-and-standalone-verify'

        $dynamicProject = @'
[package]
  cjc-version = "1.2.0"
  name = "probe"
  version = "0.1.0"
  output-type = "executable"
  compile-option = ""
  override-compile-option = ""
  link-option = ""
  package-configuration = {}

[dependencies]
'@
        $probeConfig = Join-Path $Root 'probe\cjpm.toml'
        [IO.File]::WriteAllText($probeConfig, $dynamicProject, [Text.UTF8Encoding]::new($false))
        if ((Get-Content -Raw -LiteralPath $probeConfig) -match '--static') { throw 'Mismatch project still contains --static.' }
        cjpm clean | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'Unable to clean before mismatch probe.' }
        if (Test-Path '.\target\release\bin\main.exe') { throw 'cjpm clean left the static executable behind.' }
        cjpm build | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'Unable to build dynamic mismatch executable.' }
        Write-Host "INFO mismatch executable size=$((Get-Item '.\target\release\bin\main.exe').Length)"
        & $Tool build
        if ($LASTEXITCODE -ne 5) { throw 'Dynamic binary declared static was not rejected.' }
        Write-Host 'PASS static-declaration-dynamic-binary-fails-closed'
    } finally { Pop-Location }
} finally {
    if (Test-Path -LiteralPath $Root) { Remove-Item -LiteralPath $Root -Recurse -Force }
}
exit 0
