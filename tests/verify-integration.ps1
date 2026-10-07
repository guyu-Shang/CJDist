param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)
$Base = Join-Path $ProjectRoot 'dist\MyApp'
$Verifier = Join-Path $Base 'main.exe'
$TestRoot = [IO.Path]::GetFullPath((Join-Path $ProjectRoot '.cjdist\verify-tests'))
if (-not $TestRoot.StartsWith([IO.Path]::GetFullPath((Join-Path $ProjectRoot '.cjdist')),
        [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test root.' }
function Remove-TestRoot {
    foreach ($link in @((Join-Path $TestRoot 'junction\linked'),(Join-Path $TestRoot 'root-junction'))) {
        if (Test-Path -LiteralPath $link) {
            $item = Get-Item -Force -LiteralPath $link
            if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Expected test reparse point: $link" }
            Remove-Item -LiteralPath $link -Force
        }
    }
    if (Test-Path -LiteralPath $TestRoot) { Remove-Item -LiteralPath $TestRoot -Recurse -Force }
}
Remove-TestRoot
New-Item -ItemType Directory -Path $TestRoot | Out-Null

$script:Passed = 0
$script:Failed = 0
function New-Case([string]$Name) {
    $path = Join-Path $TestRoot $Name
    Copy-Item -LiteralPath $Base -Destination $path -Recurse
    return $path
}
function Invoke-Verify([string]$Name, [string]$Path, [bool]$ShouldPass) {
    $output = & $Verifier verify $Path 2>&1 | Out-String
    $code = $LASTEXITCODE
    $ok = if ($ShouldPass) { $code -eq 0 } else { $code -eq 5 }
    if ($ok) { $script:Passed++; Write-Host "PASS $Name" }
    else { $script:Failed++; Write-Host "FAIL $Name (exit $code)`n$output" }
    return $output
}
function Read-Manifest([string]$Path) {
    Get-Content -Raw -LiteralPath (Join-Path $Path 'cjdist-manifest.json') | ConvertFrom-Json
}
function Write-Manifest([string]$Path, $Value) {
    [IO.File]::WriteAllText((Join-Path $Path 'cjdist-manifest.json'),
        ($Value | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
}
function Set-NativeProbe([string]$Path, [string]$Executable, [string[]]$Arguments,
        [int]$ExpectedExitCode, [int]$TimeoutMs) {
    $destination = Join-Path $Path 'probe.exe'
    Copy-Item -LiteralPath $Executable -Destination $destination
    $m = Read-Manifest $Path
    ($m.files | Where-Object kind -eq 'entry').kind = 'resource'
    $m.files += [pscustomobject]@{
        path='probe.exe'; kind='entry'; size=(Get-Item -LiteralPath $destination).Length
        sha256=(Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    $m.application.entry = 'probe.exe'; $m.verify.args = $Arguments
    $m.verify.expectedExitCode = $ExpectedExitCode; $m.verify.timeoutMs = $TimeoutMs
    Write-Manifest $Path $m
}

Invoke-Verify 'valid-package' $Base $true | Out-Null

$case = New-Case 'malformed'; [IO.File]::WriteAllText((Join-Path $case 'cjdist-manifest.json'), '{')
Invoke-Verify 'malformed-json' $case $false | Out-Null
$case = New-Case 'unknown'; $raw = Get-Content -Raw (Join-Path $case 'cjdist-manifest.json');
[IO.File]::WriteAllText((Join-Path $case 'cjdist-manifest.json'), ($raw -replace '^\{', '{"unknown":1,'))
Invoke-Verify 'unknown-key' $case $false | Out-Null
$case = New-Case 'duplicate-key'; $raw = Get-Content -Raw (Join-Path $case 'cjdist-manifest.json');
[IO.File]::WriteAllText((Join-Path $case 'cjdist-manifest.json'), ($raw -replace '"schemaVersion": 1,', '"schemaVersion":1,"schemaVersion":1,'))
Invoke-Verify 'duplicate-key' $case $false | Out-Null
$case = New-Case 'invalid-escape'; $raw = Get-Content -Raw (Join-Path $case 'cjdist-manifest.json');
[IO.File]::WriteAllText((Join-Path $case 'cjdist-manifest.json'), ($raw -replace '"MyApp"', '"My\qApp"'))
Invoke-Verify 'invalid-json-escape' $case $false | Out-Null
$case = New-Case 'trailing'; Add-Content -NoNewline -LiteralPath (Join-Path $case 'cjdist-manifest.json') -Value 'x'
Invoke-Verify 'trailing-json-data' $case $false | Out-Null
$case = New-Case 'wrong-type'; $m = Read-Manifest $case; $m.verify.timeoutMs = 'five'; Write-Manifest $case $m
Invoke-Verify 'wrong-json-type' $case $false | Out-Null
$case = New-Case 'missing-key'; $m = Read-Manifest $case; $m.application.PSObject.Properties.Remove('entry'); Write-Manifest $case $m
Invoke-Verify 'missing-required-key' $case $false | Out-Null
$case = New-Case 'schema'; $m = Read-Manifest $case; $m.schemaVersion = 2; Write-Manifest $case $m
Invoke-Verify 'unsupported-schema' $case $false | Out-Null
$case = New-Case 'duplicate-path'; $m = Read-Manifest $case; $copy = $m.files[1].PSObject.Copy(); $copy.path = $copy.path.ToUpperInvariant(); $m.files += $copy; Write-Manifest $case $m
Invoke-Verify 'case-insensitive-duplicate-file' $case $false | Out-Null
$case = New-Case 'entry-missing'; $m = Read-Manifest $case; $m.application.entry = 'missing.exe'; Write-Manifest $case $m
Invoke-Verify 'entry-not-in-files' $case $false | Out-Null
$case = New-Case 'two-entry'; $m = Read-Manifest $case; $m.files[1].kind = 'entry'; Write-Manifest $case $m
Invoke-Verify 'two-entry-kinds' $case $false | Out-Null
$case = New-Case 'self'; $m = Read-Manifest $case; $m.files += [pscustomobject]@{path='cjdist-manifest.json';kind='resource';size=0;sha256=('0'*64)}; Write-Manifest $case $m
Invoke-Verify 'manifest-lists-itself' $case $false | Out-Null

$case = New-Case 'missing-file'; Remove-Item -LiteralPath (Join-Path $case 'README.md')
Invoke-Verify 'missing-payload' $case $false | Out-Null
$case = New-Case 'same-size'; $p = Join-Path $case 'README.md'; $bytes = [IO.File]::ReadAllBytes($p); $bytes[0] = $bytes[0] -bxor 1; [IO.File]::WriteAllBytes($p,$bytes)
Invoke-Verify 'same-size-sha-mismatch' $case $false | Out-Null
$case = New-Case 'size'; Add-Content -NoNewline -LiteralPath (Join-Path $case 'README.md') -Value 'x'
Invoke-Verify 'size-mismatch' $case $false | Out-Null
$case = New-Case 'extra-file'; [IO.File]::WriteAllText((Join-Path $case 'old.dll'),'x')
Invoke-Verify 'unexpected-file' $case $false | Out-Null
$case = New-Case 'extra-directory'; New-Item -ItemType Directory -Path (Join-Path $case 'random') | Out-Null
Invoke-Verify 'unexpected-directory' $case $false | Out-Null
$case = New-Case 'empty-directory'; $m = Read-Manifest $case; $m.directories += 'empty'; Write-Manifest $case $m; New-Item -ItemType Directory -Path (Join-Path $case 'empty') | Out-Null
Invoke-Verify 'declared-empty-directory' $case $true | Out-Null; Remove-Item -LiteralPath (Join-Path $case 'empty')
Invoke-Verify 'missing-empty-directory' $case $false | Out-Null
$case = New-Case 'file-to-directory'; Remove-Item -LiteralPath (Join-Path $case 'README.md'); New-Item -ItemType Directory -Path (Join-Path $case 'README.md') | Out-Null
Invoke-Verify 'file-replaced-by-directory' $case $false | Out-Null
$case = New-Case 'marker'; $p = Join-Path $case '.cjdist-output'; $bytes = [IO.File]::ReadAllBytes($p); $bytes[0] = $bytes[0] -bxor 1; [IO.File]::WriteAllBytes($p,$bytes)
Invoke-Verify 'ownership-marker-sha-mismatch' $case $false | Out-Null
$case = New-Case 'runtime-missing'; Remove-Item -LiteralPath (Join-Path $case 'libcangjie-runtime.dll')
Invoke-Verify 'missing-runtime-fails-integrity' $case $false | Out-Null
$case = New-Case 'loader-failure'; $m = Read-Manifest $case; $m.files = @($m.files | Where-Object kind -ne 'runtime'); Write-Manifest $case $m; Remove-Item -LiteralPath (Join-Path $case 'libcangjie-runtime.dll'),(Join-Path $case 'libboundscheck.dll')
Invoke-Verify 'loader-failure-captured-by-startup' $case $false | Out-Null
$case = New-Case 'junction'; New-Item -ItemType Junction -Path (Join-Path $case 'linked') -Target $env:TEMP | Out-Null
Invoke-Verify 'junction-rejected' $case $false | Out-Null
$rootJunction = Join-Path $TestRoot 'root-junction'; New-Item -ItemType Junction -Path $rootJunction -Target $Base | Out-Null
Invoke-Verify 'distribution-root-junction-rejected' $rootJunction $false | Out-Null

$case = New-Case 'wrong-exit'; $m = Read-Manifest $case; $m.verify.expectedExitCode = 7; Write-Manifest $case $m
$output = Invoke-Verify 'wrong-expected-exit' $case $false
if ($output -notmatch 'exited with code 0; expected 7') { throw 'Wrong-exit diagnostic missing.' }
$case = New-Case 'expected-nonzero'; $m = Read-Manifest $case; $m.verify.args = @('unknown-command'); $m.verify.expectedExitCode = 2; Write-Manifest $case $m
Invoke-Verify 'matching-nonzero-exit' $case $true | Out-Null

$case = New-Case 'timeout'; Set-NativeProbe $case (Join-Path $env:SystemRoot 'System32\ping.exe') @('-n','10','127.0.0.1') 0 100
$output = Invoke-Verify 'startup-timeout' $case $false
if ($output -notmatch 'timed out after 100 ms') { throw 'Timeout diagnostic missing.' }
$case = New-Case 'stdio'; Set-NativeProbe $case (Join-Path $env:SystemRoot 'System32\cmd.exe') @('/d','/c','echo probe-out & echo probe-err 1>&2 & exit /b 7') 8 5000
$output = Invoke-Verify 'stdout-stderr-captured' $case $false
if ($output -notmatch 'probe-out' -or $output -notmatch 'probe-err') { throw 'Captured stdout/stderr missing.' }
$case = New-Case 'nonzero-probe'; Set-NativeProbe $case (Join-Path $env:SystemRoot 'System32\cmd.exe') @('/d','/c','exit /b 7') 7 5000
Invoke-Verify 'native-matching-nonzero' $case $true | Out-Null
$case = New-Case 'large-output'; Set-NativeProbe $case (Join-Path $env:SystemRoot 'System32\cmd.exe') @('/d','/c','for /L %i in (1,1,20000) do @echo 012345678901234567890123456789') 0 30000
Invoke-Verify 'large-output-no-deadlock' $case $true | Out-Null
$case = New-Case 'large-diagnostic'; Set-NativeProbe $case (Join-Path $env:SystemRoot 'System32\cmd.exe') @('/d','/c','for /L %i in (1,1,5000) do @echo 012345678901234567890123456789') 7 30000
$output = Invoke-Verify 'large-failure-output-truncated' $case $false
if ($output -notmatch '\(output truncated\)') { throw 'Truncation marker missing.' }

Write-Host "RESULT passed=$script:Passed failed=$script:Failed"
if ($script:Failed -ne 0) { exit 1 }
Remove-TestRoot
exit 0
