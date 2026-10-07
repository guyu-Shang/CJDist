param([string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)
$Output = Join-Path $ProjectRoot 'dist\MyApp'
$Config = Join-Path $ProjectRoot 'cjdist.toml'
$DriverRoot = [IO.Path]::GetFullPath((Join-Path $ProjectRoot '.cjdist\build-test-driver'))
if (-not $DriverRoot.StartsWith([IO.Path]::GetFullPath((Join-Path $ProjectRoot '.cjdist')),
        [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe driver root.' }
if (Test-Path -LiteralPath $DriverRoot) { Remove-Item -LiteralPath $DriverRoot -Recurse -Force }
New-Item -ItemType Directory -Path $DriverRoot | Out-Null
Copy-Item -LiteralPath (Join-Path $Output 'main.exe') -Destination (Join-Path $DriverRoot 'cjdist.exe')
Copy-Item -LiteralPath (Join-Path $Output 'libcangjie-runtime.dll') -Destination $DriverRoot
Copy-Item -LiteralPath (Join-Path $Output 'libboundscheck.dll') -Destination $DriverRoot

$sentinel = Join-Path $Output 'preserve-me.sentinel'
$configBytes = [IO.File]::ReadAllBytes($Config)
[IO.File]::WriteAllText($sentinel, 'old-output-must-survive', [Text.UTF8Encoding]::new($false))
function Get-TreeState {
    Get-ChildItem -LiteralPath $Output -File -Recurse | Sort-Object FullName | ForEach-Object {
        "{0}|{1}|{2}" -f $_.FullName.Substring($Output.Length),$_.Length,
            (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
    }
}
$before = Get-TreeState
try {
    $text = [Text.Encoding]::UTF8.GetString($configBytes)
    if ($text -notmatch 'expected-exit-code = 0') { throw 'Expected baseline verify setting was not found.' }
    [IO.File]::WriteAllText($Config, ($text -replace 'expected-exit-code = 0','expected-exit-code = 7'),
        [Text.UTF8Encoding]::new($false))
    Push-Location $ProjectRoot
    try { & (Join-Path $DriverRoot 'cjdist.exe') build 2>&1 | Out-Host; $code = $LASTEXITCODE }
    finally { Pop-Location }
    if ($code -ne 5) { throw "Failing build returned $code instead of 5." }
    $after = Get-TreeState
    if (Compare-Object $before $after) { throw 'Existing output changed after pre-publication verify failure.' }
    if ([IO.File]::ReadAllText($sentinel) -ne 'old-output-must-survive') { throw 'Sentinel content changed.' }
    Write-Host 'PASS build-prepublish-failure-preserved-old-output'
} finally {
    [IO.File]::WriteAllBytes($Config, $configBytes)
    if (Test-Path -LiteralPath $sentinel) { Remove-Item -LiteralPath $sentinel }
    if (Test-Path -LiteralPath $DriverRoot) { Remove-Item -LiteralPath $DriverRoot -Recurse -Force }
}
exit 0
