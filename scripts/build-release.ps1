[CmdletBinding()]
param(
    [string]$OutputDirectory,
    [string]$BuildName,
    [string]$BuildNumber,
    [string]$CertificateThumbprint,
    [string]$TimestampUrl = 'http://timestamp.digicert.com',
    [switch]$SkipTests,
    [switch]$CreateInstaller
)

$ErrorActionPreference = 'Stop'
$ScriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepositoryRoot = Split-Path -Parent $ScriptDirectory

function Invoke-SignFile {
    param([Parameter(Mandatory)][string]$Path)

    Write-Host "==> Signing $(Split-Path $Path -Leaf)"
    & $script:SignTool sign /sha1 $CertificateThumbprint /fd SHA256 /tr $TimestampUrl /td SHA256 $Path
    if ($LASTEXITCODE -ne 0) {
        throw "signtool failed for $Path with exit code $LASTEXITCODE"
    }
    & $script:SignTool verify /pa $Path
    if ($LASTEXITCODE -ne 0) {
        throw "signature verification failed for $Path with exit code $LASTEXITCODE"
    }
}

function Find-InnoSetupCompiler {
    $command = Get-Command iscc.exe -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }
    $candidates = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
        (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe')
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path $candidate)) {
            return $candidate
        }
    }
    throw 'Inno Setup 6 (ISCC.exe) is required for -CreateInstaller; install it with "choco install innosetup" or from https://jrsoftware.org/isinfo.php'
}

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

    # Flutter's Windows runner links the MSVC runtime dynamically. Bundle it so
    # the app starts on machines without the Visual C++ Redistributable.
    foreach ($runtimeDll in @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
        $runtimePath = Join-Path $env:WINDIR "System32\$runtimeDll"
        if (Test-Path $runtimePath) {
            Copy-Item $runtimePath $stagingDirectory -Force
        } else {
            Write-Warning "$runtimeDll not found; target machines will need the Visual C++ Redistributable"
        }
    }

    $shouldSign = -not [string]::IsNullOrWhiteSpace($CertificateThumbprint)
    if ($shouldSign) {
        $signToolCommand = Get-Command signtool.exe -ErrorAction SilentlyContinue
        if (-not $signToolCommand) {
            throw 'signtool.exe is required when CertificateThumbprint is provided'
        }
        $script:SignTool = $signToolCommand.Source
        # Microsoft runtime DLLs are already signed by Microsoft.
        $signableFiles = Get-ChildItem $stagingDirectory -Recurse -File |
            Where-Object { $_.Extension -in @('.exe', '.dll') } |
            Where-Object { $_.Name -notin @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll') }
        foreach ($file in $signableFiles) {
            Invoke-SignFile -Path $file.FullName
        }
    } else {
        Write-Warning 'package is unsigned; pass -CertificateThumbprint for external distribution'
    }

    Compress-Archive -Path (Join-Path $stagingDirectory '*') -DestinationPath $zipPath -CompressionLevel Optimal
    $hash = (Get-FileHash $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $(Split-Path $zipPath -Leaf)" | Set-Content $checksumPath -Encoding ascii

    $installerPath = $null
    if ($CreateInstaller) {
        $iscc = Find-InnoSetupCompiler
        $installerScript = Join-Path $RepositoryRoot 'windows\installer\ClipboardManager.iss'
        $installerPath = Join-Path $OutputDirectory "$artifactName-Setup.exe"
        Remove-Item $installerPath -Force -ErrorAction SilentlyContinue
        Remove-Item "$installerPath.sha256" -Force -ErrorAction SilentlyContinue

        Write-Host "==> Building installer with $iscc"
        & $iscc "/DAppVersion=$BuildName" "/DSourceDir=$stagingDirectory" "/DOutputDir=$OutputDirectory" $installerScript
        if ($LASTEXITCODE -ne 0) {
            throw "ISCC failed with exit code $LASTEXITCODE"
        }
        if (-not (Test-Path $installerPath)) {
            throw "installer not found: $installerPath"
        }
        if ($shouldSign) {
            Invoke-SignFile -Path $installerPath
        }
        $installerHash = (Get-FileHash $installerPath -Algorithm SHA256).Hash.ToLowerInvariant()
        "$installerHash  $(Split-Path $installerPath -Leaf)" | Set-Content "$installerPath.sha256" -Encoding ascii
    }

    Write-Host '==> Release artifacts'
    Write-Host "Directory: $stagingDirectory"
    Write-Host "Archive:   $zipPath"
    Write-Host "SHA-256:   $checksumPath"
    if ($installerPath) {
        Write-Host "Installer: $installerPath"
        Write-Host "SHA-256:   $installerPath.sha256"
    }
} finally {
    Pop-Location
}
