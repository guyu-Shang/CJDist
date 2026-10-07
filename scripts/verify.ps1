param(
    [Parameter(Mandatory = $true)]
    [string]$Sdk,
    [string]$StaticSdk
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$Sdk = [IO.Path]::GetFullPath($Sdk)
$SdkSetup = Join-Path $Sdk 'envsetup.ps1'
$Cjpm = Join-Path $Sdk 'tools\bin\cjpm.exe'
$Cjc = Join-Path $Sdk 'bin\cjc.exe'
$OriginalPath = $env:Path
$OriginalCangjieHome = $env:CANGJIE_HOME
$HadCangjieHome = Test-Path Env:CANGJIE_HOME

function Assert-NativeSuccess([string]$Step) {
    if ($LASTEXITCODE -ne 0) { throw "$Step failed with exit code $LASTEXITCODE." }
}

function Invoke-TestScript([string]$Name, [string]$Path, [hashtable]$Parameters = @{}) {
    Write-Host "`n== $Name =="
    & $Path @Parameters
    Assert-NativeSuccess $Name
}

foreach ($required in @($SdkSetup, $Cjpm, $Cjc)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required SDK file not found: $required"
    }
}

try {
    . $SdkSetup
    if (-not [IO.Path]::GetFullPath($env:CANGJIE_HOME).Equals($Sdk, [StringComparison]::OrdinalIgnoreCase)) {
        throw "envsetup.ps1 selected an unexpected SDK: $env:CANGJIE_HOME"
    }

    Write-Host '== SDK baseline =='
    & $Cjpm --version | Out-Host
    Assert-NativeSuccess 'cjpm --version'
    & $Cjc --version | Out-Host
    Assert-NativeSuccess 'cjc --version'

    Push-Location $ProjectRoot
    try {
        Write-Host "`n== Clean and compile CJDist =="
        & $Cjpm clean | Out-Host
        Assert-NativeSuccess 'cjpm clean'
        & $Cjpm build -o cjdist | Out-Host
        Assert-NativeSuccess 'cjpm build -o cjdist'

        $Bootstrap = Join-Path $ProjectRoot 'target\release\bin\cjdist.exe'
        if (-not (Test-Path -LiteralPath $Bootstrap -PathType Leaf)) {
            throw "CJDist bootstrap executable was not produced: $Bootstrap"
        }
        & $Bootstrap --version | Out-Host
        Assert-NativeSuccess 'cjdist --version'
        & $Bootstrap --help | Out-Host
        Assert-NativeSuccess 'cjdist --help'

        Write-Host "`n== Dynamic self-build and publication =="
        & $Bootstrap build 2>&1 | Out-Host
        Assert-NativeSuccess 'cjdist build'

        Invoke-TestScript 'verify integration' (Join-Path $ProjectRoot 'tests\verify-integration.ps1')
        Invoke-TestScript 'archive integration' (Join-Path $ProjectRoot 'tests\archive-integration.ps1')
        Invoke-TestScript 'fail-closed publication' (Join-Path $ProjectRoot 'tests\build-fail-closed.ps1')
        Invoke-TestScript 'recursive-removal safety' (Join-Path $ProjectRoot 'tests\removal-safety.ps1')

        $Standalone = Join-Path $ProjectRoot 'dist\MyApp\main.exe'
        Write-Host "`n== Standalone verification =="
        & $Standalone verify (Join-Path $ProjectRoot 'dist\MyApp') 2>&1 | Out-Host
        Assert-NativeSuccess 'standalone verify'

        Write-Host "`n== No-SDK standalone verification =="
        $SdkPath = $env:Path
        $SdkHome = $env:CANGJIE_HOME
        try {
            Remove-Item Env:CANGJIE_HOME -ErrorAction SilentlyContinue
            $env:Path = (Join-Path $env:SystemRoot 'System32') + ';' + $env:SystemRoot
            & $Standalone verify (Join-Path $ProjectRoot 'dist\MyApp') 2>&1 | Out-Host
            Assert-NativeSuccess 'no-SDK standalone verify'
        } finally {
            $env:Path = $SdkPath
            $env:CANGJIE_HOME = $SdkHome
        }

        if ([string]::IsNullOrWhiteSpace($StaticSdk)) {
            Write-Host "`nSKIP Cangjie 1.2 compatibility/static tests (-StaticSdk was not provided)."
        } else {
            $StaticSdk = [IO.Path]::GetFullPath($StaticSdk)
            if (-not (Test-Path -LiteralPath (Join-Path $StaticSdk 'envsetup.ps1') -PathType Leaf)) {
                throw "Static SDK envsetup.ps1 not found: $StaticSdk"
            }
            Invoke-TestScript 'Cangjie 1.2 compile and dynamic compatibility' `
                (Join-Path $ProjectRoot 'tests\compatibility-1.2.ps1') `
                @{SdkRoot = $StaticSdk}
            . $SdkSetup
            Invoke-TestScript 'Cangjie 1.2 static integration' `
                (Join-Path $ProjectRoot 'tests\static-1.2-integration.ps1') `
                @{SdkRoot = $StaticSdk}
            . $SdkSetup
        }
        Write-Host "`nRELEASE VERIFICATION PASS"
    } finally {
        Pop-Location
    }
} finally {
    $env:Path = $OriginalPath
    if ($HadCangjieHome) { $env:CANGJIE_HOME = $OriginalCangjieHome }
    else { Remove-Item Env:CANGJIE_HOME -ErrorAction SilentlyContinue }
}
