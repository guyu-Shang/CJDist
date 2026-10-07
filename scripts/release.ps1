param(
    [Parameter(Mandatory = $true)]
    [string]$Sdk
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$Sdk = [IO.Path]::GetFullPath($Sdk)
$SdkSetup = Join-Path $Sdk 'envsetup.ps1'
$Cjpm = Join-Path $Sdk 'tools\bin\cjpm.exe'
$Cjc = Join-Path $Sdk 'bin\cjc.exe'
$DevelopmentConfig = Join-Path $ProjectRoot 'cjdist.toml'
$ReleaseConfig = Join-Path $ProjectRoot 'packaging\cjdist-release.toml'
$ReleaseRoot = Join-Path $ProjectRoot 'release'
$ReleaseDirectory = Join-Path $ReleaseRoot 'cjdist-0.1.0-windows-x64'
$ReleaseArchive = Join-Path $ReleaseRoot 'cjdist-0.1.0-windows-x64.zip'
$ExtractRoot = Join-Path $ProjectRoot '.cjdist\release-candidate-extract'
$OriginalPath = $env:Path
$OriginalCangjieHome = $env:CANGJIE_HOME
$HadCangjieHome = Test-Path Env:CANGJIE_HOME

function Assert-NativeSuccess([string]$Step) {
    if ($LASTEXITCODE -ne 0) { throw "$Step failed with exit code $LASTEXITCODE." }
}

function Remove-OwnedExtraction {
    if (-not (Test-Path -LiteralPath $ExtractRoot)) { return }
    $ownedParent = [IO.Path]::GetFullPath((Join-Path $ProjectRoot '.cjdist'))
    if ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($ExtractRoot)) -ne $ownedParent) {
        throw 'Refusing unsafe extraction cleanup target.'
    }
    $rootItem = Get-Item -Force -LiteralPath $ExtractRoot
    if ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'Refusing to remove a reparse-point extraction root.'
    }
    $links = @(Get-ChildItem -Force -LiteralPath $ExtractRoot -Recurse |
        Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })
    if ($links.Count -ne 0) { throw 'Refusing to remove an extraction tree containing reparse points.' }
    Remove-Item -LiteralPath $ExtractRoot -Recurse -Force
}

foreach ($required in @($SdkSetup, $Cjpm, $Cjc, $DevelopmentConfig, $ReleaseConfig)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Required release input not found: $required" }
}
if (Test-Path -LiteralPath $ReleaseDirectory) { throw "Release directory already exists: $ReleaseDirectory" }
if (Test-Path -LiteralPath $ReleaseArchive) { throw "Release archive already exists: $ReleaseArchive" }
if (Test-Path -LiteralPath $ExtractRoot) { throw "Extraction test directory already exists: $ExtractRoot" }

$DevelopmentConfigBytes = [IO.File]::ReadAllBytes($DevelopmentConfig)
$ReleaseConfigBytes = [IO.File]::ReadAllBytes($ReleaseConfig)
$ConfigReplaced = $false

try {
    . $SdkSetup
    $cjpmVersion = (& $Cjpm --version 2>&1 | Out-String).Trim()
    Assert-NativeSuccess 'cjpm --version'
    $cjcVersion = (& $Cjc --version 2>&1 | Out-String).Trim()
    Assert-NativeSuccess 'cjc --version'
    if ($cjpmVersion -notmatch '1\.0\.5' -or $cjcVersion -notmatch '1\.0\.5') {
        throw "CJDist 0.1.0 release must use the Cangjie 1.0.5 baseline.`n$cjpmVersion`n$cjcVersion"
    }
    Write-Host $cjpmVersion
    Write-Host $cjcVersion

    Push-Location $ProjectRoot
    try {
        & $Cjpm clean | Out-Host
        Assert-NativeSuccess 'cjpm clean'
        & $Cjpm build -o cjdist | Out-Host
        Assert-NativeSuccess 'cjpm build -o cjdist'
        $Bootstrap = Join-Path $ProjectRoot 'target\release\bin\cjdist.exe'
        & $Bootstrap --version | Out-Host
        Assert-NativeSuccess 'bootstrap cjdist --version'

        [IO.File]::WriteAllBytes($DevelopmentConfig, $ReleaseConfigBytes)
        $ConfigReplaced = $true
        try {
            & $Bootstrap build 2>&1 | Out-Host
            $releaseBuildExit = $LASTEXITCODE
        } finally {
            [IO.File]::WriteAllBytes($DevelopmentConfig, $DevelopmentConfigBytes)
            $ConfigReplaced = $false
        }
        if ($releaseBuildExit -ne 0) { throw "CJDist self-host release build failed with exit code $releaseBuildExit." }

        $ReleaseExe = Join-Path $ReleaseDirectory 'cjdist.exe'
        & $Bootstrap verify $ReleaseDirectory 2>&1 | Out-Host
        Assert-NativeSuccess 'bootstrap standalone verify'
        & $Bootstrap archive $ReleaseDirectory 2>&1 | Out-Host
        Assert-NativeSuccess 'bootstrap archive'

        New-Item -ItemType Directory -Path $ExtractRoot | Out-Null
        try {
            Expand-Archive -LiteralPath $ReleaseArchive -DestinationPath $ExtractRoot
            $children = @(Get-ChildItem -Force -LiteralPath $ExtractRoot)
            if ($children.Count -ne 1 -or -not $children[0].PSIsContainer -or
                $children[0].Name -ne 'cjdist-0.1.0-windows-x64') {
                throw 'Release archive does not contain exactly the expected top-level directory.'
            }
            & $ReleaseExe verify $children[0].FullName 2>&1 | Out-Host
            Assert-NativeSuccess 'independently extracted archive verify'
        } finally {
            Remove-OwnedExtraction
        }

        Write-Host "`n== No-SDK portable checks =="
        $SdkPath = $env:Path
        $SdkHome = $env:CANGJIE_HOME
        try {
            Remove-Item Env:CANGJIE_HOME -ErrorAction SilentlyContinue
            $env:Path = $ReleaseDirectory + ';' + (Join-Path $env:SystemRoot 'System32') + ';' + $env:SystemRoot
            & $ReleaseExe --version | Out-Host
            Assert-NativeSuccess 'portable --version'
            & $ReleaseExe --help | Out-Host
            Assert-NativeSuccess 'portable --help'
            & $ReleaseExe verify $ReleaseDirectory 2>&1 | Out-Host
            Assert-NativeSuccess 'portable verify'
            $buildFailure = & $ReleaseExe build 2>&1 | Out-String
            $buildFailureCode = $LASTEXITCODE
            $buildFailure | Write-Host
            if ($buildFailureCode -ne 5 -or $buildFailure -notmatch 'ERROR Toolchain') {
                throw 'Portable build without an SDK did not fail with ERROR Toolchain / exit 5.'
            }
        } finally {
            $env:Path = $SdkPath
            $env:CANGJIE_HOME = $SdkHome
        }

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archiveInfo = Get-Item -LiteralPath $ReleaseArchive
        $archiveHash = (Get-FileHash -LiteralPath $ReleaseArchive -Algorithm SHA256).Hash.ToLowerInvariant()
        $zip = [IO.Compression.ZipFile]::OpenRead($ReleaseArchive)
        try { $entryCount = $zip.Entries.Count } finally { $zip.Dispose() }
        Write-Host "`nRELEASE CANDIDATE PASS"
        Write-Host "File: $($archiveInfo.Name)"
        Write-Host "Size: $($archiveInfo.Length)"
        Write-Host "SHA-256: $archiveHash"
        Write-Host "Entries: $entryCount"
    } finally {
        if ($ConfigReplaced) { [IO.File]::WriteAllBytes($DevelopmentConfig, $DevelopmentConfigBytes) }
        Pop-Location
    }
} finally {
    $env:Path = $OriginalPath
    if ($HadCangjieHome) { $env:CANGJIE_HOME = $OriginalCangjieHome }
    else { Remove-Item Env:CANGJIE_HOME -ErrorAction SilentlyContinue }
}
