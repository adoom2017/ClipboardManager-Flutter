[CmdletBinding()]
param(
    [string]$OutputDirectory,
    [string]$BuildName,
    [string]$BuildNumber,
    [string]$CertificateThumbprint,
    [string]$TimestampUrl = 'http://timestamp.digicert.com',
    [switch]$SkipTests
)

$ErrorActionPreference = 'Stop'
$ScriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepositoryRoot = Split-Path -Parent $ScriptDirectory

function Invoke-Flutter {
    param([Parameter(Mandatory)][string[]]$FlutterArguments)

    & flutter @FlutterArguments
    if ($LASTEXITCODE -ne 0) {
        throw "flutter $($FlutterArguments -join ' ') failed with exit code $LASTEXITCODE"
    }
}

if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    throw 'flutter is not available on PATH'
}

if ($env:OS -ne 'Windows_NT') {
    throw 'Windows release packages must be built on a Windows host'
}

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $RepositoryRoot 'build\release'
}

Push-Location $RepositoryRoot
try {
    Write-Host '==> Restoring dependencies'
    Invoke-Flutter -FlutterArguments @('pub', 'get')

    Write-Host '==> Running static analysis'
    Invoke-Flutter -FlutterArguments @('analyze')

    if (-not $SkipTests) {
        Write-Host '==> Running tests'
        Invoke-Flutter -FlutterArguments @('test')
    }

    $buildArguments = @('build', 'windows', '--release')
    if (-not [string]::IsNullOrWhiteSpace($BuildName)) {
        $buildArguments += @('--build-name', $BuildName)
    }
    if (-not [string]::IsNullOrWhiteSpace($BuildNumber)) {
        $buildArguments += @('--build-number', $BuildNumber)
    }

    Write-Host '==> Building Windows Release'
    Invoke-Flutter -FlutterArguments $buildArguments

    $sourceDirectory = Join-Path $RepositoryRoot 'build\windows\x64\runner\Release'
    if (-not (Test-Path $sourceDirectory)) {
        throw "release directory not found: $sourceDirectory"
    }

    if ([string]::IsNullOrWhiteSpace($BuildName)) {
        $pubspec = Get-Content (Join-Path $RepositoryRoot 'pubspec.yaml')
        $versionLine = $pubspec | Where-Object { $_ -match '^version:\s*([^+\s]+)' } | Select-Object -First 1
        if ($versionLine -match '^version:\s*([^+\s]+)') {
            $BuildName = $Matches[1]
        } else {
            $BuildName = 'unknown'
        }
    }

    $artifactName = "ClipboardManager-Windows-$BuildName"
    $stagingDirectory = Join-Path $OutputDirectory $artifactName
    $zipPath = Join-Path $OutputDirectory "$artifactName.zip"
    $checksumPath = "$zipPath.sha256"

    Write-Host "==> Packaging $artifactName"
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    Remove-Item $stagingDirectory -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
    Remove-Item $checksumPath -Force -ErrorAction SilentlyContinue
    Copy-Item $sourceDirectory $stagingDirectory -Recurse

    $executable = Get-ChildItem $stagingDirectory -Filter '*.exe' -File | Select-Object -First 1
    if (-not $executable) {
        throw "no executable found in $stagingDirectory"
    }

    if (-not [string]::IsNullOrWhiteSpace($CertificateThumbprint)) {
        $signTool = Get-Command signtool.exe -ErrorAction SilentlyContinue
        if (-not $signTool) {
            throw 'signtool.exe is required when CertificateThumbprint is provided'
        }
        $signableFiles = Get-ChildItem $stagingDirectory -Recurse -File |
            Where-Object { $_.Extension -in @('.exe', '.dll') }
        foreach ($file in $signableFiles) {
            Write-Host "==> Signing $($file.Name)"
            & $signTool.Source sign /sha1 $CertificateThumbprint /fd SHA256 /tr $TimestampUrl /td SHA256 $file.FullName
            if ($LASTEXITCODE -ne 0) {
                throw "signtool failed for $($file.FullName) with exit code $LASTEXITCODE"
            }
            & $signTool.Source verify /pa $file.FullName
            if ($LASTEXITCODE -ne 0) {
                throw "signature verification failed for $($file.FullName) with exit code $LASTEXITCODE"
            }
        }
    } else {
        Write-Warning 'package is unsigned; pass -CertificateThumbprint for external distribution'
    }

    Compress-Archive -Path (Join-Path $stagingDirectory '*') -DestinationPath $zipPath -CompressionLevel Optimal
    $hash = (Get-FileHash $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $(Split-Path $zipPath -Leaf)" | Set-Content $checksumPath -Encoding ascii

    Write-Host '==> Release artifacts'
    Write-Host "Directory: $stagingDirectory"
    Write-Host "Archive:   $zipPath"
    Write-Host "SHA-256:   $checksumPath"
} finally {
    Pop-Location
}
