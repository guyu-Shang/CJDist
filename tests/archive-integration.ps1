param([string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)
$Base = Join-Path $ProjectRoot 'dist\MyApp'
$Tool = Join-Path $Base 'main.exe'
$Root = [IO.Path]::GetFullPath((Join-Path $ProjectRoot '.cjdist\archive-tests'))
$Owned = [IO.Path]::GetFullPath((Join-Path $ProjectRoot '.cjdist'))
if ([IO.Path]::GetDirectoryName($Root) -ne $Owned) { throw 'Unsafe archive test root.' }
if (Test-Path -LiteralPath $Root) { Remove-Item -LiteralPath $Root -Recurse -Force }
New-Item -ItemType Directory -Path $Root | Out-Null
$script:Passed = 0
function Assert([bool]$Condition, [string]$Name) {
    if (-not $Condition) { throw "FAIL $Name" }
    $script:Passed++; Write-Host "PASS $Name"
}
function Copy-Case([string]$Name) {
    $parent = Join-Path $Root $Name
    New-Item -ItemType Directory -Path $parent | Out-Null
    $source = Join-Path $parent 'distribution with space'
    Copy-Item -LiteralPath $Base -Destination $source -Recurse
    return $source
}
function Invoke-Archive([string]$Source) {
    $output = & $Tool archive $Source 2>&1 | Out-String
    return [pscustomobject]@{Code=$LASTEXITCODE;Output=$output}
}
try {
    $source = Copy-Case 'normal'
    $result = Invoke-Archive $source
    Assert ($result.Code -eq 0) 'verified-distribution-archives'
    $zip = Join-Path (Split-Path $source -Parent) 'MyApp-windows-x64.zip'
    Assert (Test-Path -LiteralPath $zip -PathType Leaf) 'archive-created-outside-distribution'
    $before = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
    $again = Invoke-Archive $source
    Assert ($again.Code -eq 5) 'existing-archive-refuses-overwrite'
    Assert ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -eq $before) 'existing-archive-unchanged'

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $opened = [IO.Compression.ZipFile]::OpenRead($zip)
    try { $entries = @($opened.Entries | ForEach-Object FullName) } finally { $opened.Dispose() }
    Assert (($entries | Where-Object { -not $_.StartsWith('MyApp-windows-x64/') }).Count -eq 0) 'single-expected-root-prefix'
    Assert (($entries | Where-Object { $_ -match '\.ps1$|\.log$' }).Count -eq 0) 'no-helper-or-log-leakage'

    $extract = Join-Path $Root 'manual-extract'
    Microsoft.PowerShell.Archive\Expand-Archive -LiteralPath $zip -DestinationPath $extract
    & $Tool verify (Join-Path $extract 'MyApp-windows-x64') | Out-Host
    Assert ($LASTEXITCODE -eq 0) 'independently-extracted-archive-standalone-verifies'

    $tampered = Copy-Case 'tampered'
    Add-Content -NoNewline -LiteralPath (Join-Path $tampered 'README.md') -Value 'tampered'
    $bad = Invoke-Archive $tampered
    Assert ($bad.Code -eq 5) 'tampered-source-rejected-before-archive'
    Assert (-not (Test-Path -LiteralPath (Join-Path (Split-Path $tampered -Parent) 'MyApp-windows-x64.zip'))) 'tampered-source-produces-no-zip'

    $complex = Copy-Case 'complex'
    $nested = Join-Path $complex 'Folder With Space\Nested'
    $empty = Join-Path $complex 'Folder With Space\empty'
    New-Item -ItemType Directory -Path $nested,$empty | Out-Null
    $resource = Join-Path $nested 'file name.txt'
    [IO.File]::WriteAllText($resource, 'nested resource', [Text.UTF8Encoding]::new($false))
    $manifestPath = Join-Path $complex 'cjdist-manifest.json'
    $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
    $manifest.directories = @('Folder With Space','Folder With Space/Nested','Folder With Space/empty')
    $manifest.files += [pscustomobject]@{
        path='Folder With Space/Nested/file name.txt'; kind='resource'
        size=(Get-Item -LiteralPath $resource).Length
        sha256=(Get-FileHash -LiteralPath $resource -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
    $complexResult = Invoke-Archive $complex
    Assert ($complexResult.Code -eq 0) 'spaces-nested-and-empty-directories-archive'
    $complexZip = Join-Path (Split-Path $complex -Parent) 'MyApp-windows-x64.zip'
    $opened = [IO.Compression.ZipFile]::OpenRead($complexZip)
    try { $complexEntries = @($opened.Entries | ForEach-Object FullName) } finally { $opened.Dispose() }
    Assert ($complexEntries -contains 'MyApp-windows-x64/Folder With Space/Nested/file name.txt') 'nested-space-file-layout-preserved'
    Assert ($complexEntries -contains 'MyApp-windows-x64/Folder With Space/empty/') 'explicit-empty-directory-preserved'
    Assert (($complexEntries | Where-Object { $_ -match '\.ps1$|\.log$' }).Count -eq 0) 'complex-archive-no-temp-leakage'

    $unsafeName = Copy-Case 'sanitized-name'
    $unsafeManifestPath = Join-Path $unsafeName 'cjdist-manifest.json'
    $unsafeManifest = Get-Content -Raw -LiteralPath $unsafeManifestPath | ConvertFrom-Json
    $unsafeManifest.application.name = 'My App:测试/CON.'
    [IO.File]::WriteAllText($unsafeManifestPath, ($unsafeManifest | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
    $unsafeResult = Invoke-Archive $unsafeName
    Assert ($unsafeResult.Code -eq 0) 'unsafe-and-unicode-application-name-sanitized'
    Assert (Test-Path -LiteralPath (Join-Path (Split-Path $unsafeName -Parent) 'My-App-CON-windows-x64.zip')) 'deterministic-sanitized-archive-name'

    Write-Host "RESULT passed=$script:Passed failed=0"
} finally {
    if (Test-Path -LiteralPath $Root) { Remove-Item -LiteralPath $Root -Recurse -Force }
}
exit 0
