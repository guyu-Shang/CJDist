param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot),
    [Parameter(Mandatory = $true)]
    [string]$SdkRoot
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)
$SdkRoot = [IO.Path]::GetFullPath($SdkRoot)
$OwnedRoot = [IO.Path]::GetFullPath((Join-Path $ProjectRoot '.cjdist'))
$Root = [IO.Path]::GetFullPath((Join-Path $OwnedRoot 'compatibility-1.2-tests'))
$Tool = Join-Path $ProjectRoot 'dist\MyApp\main.exe'
if ([IO.Path]::GetDirectoryName($Root) -ne $OwnedRoot) { throw 'Unsafe compatibility test root.' }
if (-not (Test-Path -LiteralPath (Join-Path $SdkRoot 'envsetup.ps1') -PathType Leaf)) {
    throw "Cangjie 1.2 SDK not found: $SdkRoot"
}
if (Test-Path -LiteralPath $Root) { Remove-Item -LiteralPath $Root -Recurse -Force }
New-Item -ItemType Directory -Path $Root | Out-Null
Copy-Item -LiteralPath (Join-Path $ProjectRoot 'src') -Destination (Join-Path $Root 'src') -Recurse

$project = @'
[package]
  cjc-version = "1.2.0"
  name = "cjdist"
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
name = "CJDistCompat"
entry = "target/release/bin/main.exe"
output-dir = "dist/CJDistCompat"

[dist.runtime]
mode = "dynamic"
source = "build-sdk"

[dist.files]
include = []
dlls = []
licenses = []

[dist.verify]
args = ["--version"]
expected-exit-code = 0
timeout-ms = 5000
working-directory = "package-root"
'@
[IO.File]::WriteAllText((Join-Path $Root 'cjpm.toml'), $project, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $Root 'cjdist.toml'), $config, [Text.UTF8Encoding]::new($false))

try {
    . (Join-Path $SdkRoot 'envsetup.ps1')
    Push-Location $Root
    try {
        cjpm clean | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'Cangjie 1.2 compatibility clean failed.' }
        cjpm build -o cjdist-compat | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'CJDist did not compile with Cangjie 1.2.' }
        & (Join-Path $Root 'target\release\bin\cjdist-compat.exe') --version | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'Cangjie 1.2-built CJDist did not start.' }

        & $Tool build 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'Cangjie 1.2 dynamic packaging failed.' }
        & $Tool verify '.\dist\CJDistCompat' 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'Cangjie 1.2 dynamic distribution verification failed.' }
        $manifest = Get-Content -Raw -LiteralPath '.\dist\CJDistCompat\cjdist-manifest.json' | ConvertFrom-Json
        if ($manifest.runtime.mode -ne 'dynamic') { throw 'Cangjie 1.2 dynamic manifest mode mismatch.' }
        if ($manifest.toolchain.cjcVersion -notmatch '1\.2\.0') { throw 'Manifest did not record the Cangjie 1.2 compiler.' }
        Write-Host 'PASS cangjie-1.2-compile-dynamic-build-and-verify'
    } finally {
        Pop-Location
    }
} finally {
    if (Test-Path -LiteralPath $Root) { Remove-Item -LiteralPath $Root -Recurse -Force }
}
exit 0
