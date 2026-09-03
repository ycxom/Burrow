param(
    [ValidateSet("arm64-v8a", "x86_64")]
    [string[]]$Abi = @("arm64-v8a", "x86_64"),

    [switch]$Debug,
    [switch]$Install,
    [switch]$SkipProot,
    [switch]$RunChecks,

    [string]$Adb = "",

    [string]$Serial = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Push-Location $ProjectRoot

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Resolve-FullPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if (-not (Test-Path -LiteralPath $expanded)) {
        return $expanded
    }

    return (Resolve-Path -LiteralPath $expanded).Path
}

function Read-LocalProperties {
    $result = @{}
    $file = Join-Path $ProjectRoot "android\local.properties"
    if (-not (Test-Path -LiteralPath $file)) {
        return $result
    }

    foreach ($line in [System.IO.File]::ReadAllLines($file)) {
        if ($line -match "^\s*([^#=:\s]+)\s*=\s*(.*?)\s*$") {
            $result[$Matches[1]] = $Matches[2]
        }
    }

    return $result
}

function Find-Flutter {
    $localProperties = Read-LocalProperties
    $candidates = @()

    foreach ($name in @("FLUTTER_HOME", "FLUTTER_SDK")) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $candidates += $value
        }
    }

    $pathCommand = Get-Command "flutter.bat" -ErrorAction SilentlyContinue
    if ($pathCommand) {
        $candidates += $pathCommand.Source
    }

    if ($localProperties.ContainsKey("flutter.sdk")) {
        $candidates += $localProperties["flutter.sdk"]
    }

    foreach ($candidate in $candidates) {
        $root = Resolve-FullPath $candidate
        if ((Split-Path -Leaf $root) -eq "bin") {
            $root = Split-Path -Parent $root
        }

        $flutter = Join-Path $root "bin\flutter.bat"
        if (Test-Path -LiteralPath $flutter) {
            return $flutter
        }
    }

    throw "Flutter SDK not found. Set FLUTTER_HOME or FLUTTER_SDK, or add flutter.bat to PATH."
}

function Find-AndroidSdk {
    param([hashtable]$Properties)

    $candidates = @(
        [Environment]::GetEnvironmentVariable("ANDROID_SDK_ROOT"),
        [Environment]::GetEnvironmentVariable("ANDROID_SDK_HOME"),
        $Properties["sdk.dir"],
        (Join-Path $env:LOCALAPPDATA "Android\Sdk")
    )

    foreach ($candidate in $candidates) {
        $sdk = Resolve-FullPath $candidate
        if ($sdk -and (Test-Path -LiteralPath (Join-Path $sdk "platform-tools"))) {
            return $sdk
        }
    }

    return $null
}

function Find-Ndk {
    $candidates = @(
        [Environment]::GetEnvironmentVariable("ANDROID_NDK_HOME"),
        [Environment]::GetEnvironmentVariable("ANDROID_NDK_ROOT")
    )

    foreach ($candidate in $candidates) {
        $ndk = Resolve-FullPath $candidate
        if (Test-Ndk -NdkRoot $ndk) {
            return $ndk
        }
    }

    $sdkNdkRoot = $null
    if ($Script:AndroidSdk) {
        $sdkNdkRoot = Join-Path $Script:AndroidSdk "ndk"
    }

    if ($sdkNdkRoot -and (Test-Path -LiteralPath $sdkNdkRoot)) {
        $versions = Get-ChildItem -LiteralPath $sdkNdkRoot -Directory | ForEach-Object {
            $version = $null
            if ([System.Version]::TryParse($_.Name, [ref]$version)) {
                [PSCustomObject]@{ Path = $_.FullName; Version = $version }
            }
        }

        $newest = $versions | Sort-Object -Property Version -Descending | Select-Object -First 1
        if ($newest -and (Test-Ndk -NdkRoot $newest.Path)) {
            return $newest.Path
        }
    }

    return $null
}

function Test-Ndk {
    param([string]$NdkRoot)

    if (-not $NdkRoot) {
        return $false
    }

    return Test-Path -LiteralPath (Join-Path $NdkRoot "toolchains\llvm\prebuilt\windows-x86_64\bin\clang.exe")
}

function Test-ProotArtifacts {
    $names = @("libproot.so", "libproot-loader.so", "libproot-loader32.so")
    foreach ($target in $Abi) {
        foreach ($name in $names) {
            $file = Join-Path $ProjectRoot "android\app\src\main\jniLibs\$target\$name"
            if (-not (Test-Path -LiteralPath $file) -or ((Get-Item -LiteralPath $file).Length -le 0)) {
                return $false
            }
        }
    }

    return $true
}

function Invoke-Checked {
    param(
        [string]$FilePath,
        [string[]]$Arguments = @()
    )

    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code ${LASTEXITCODE}: $FilePath $($Arguments -join ' ')"
    }
}

function Convert-ToWslPath {
    param([string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $drive = [System.IO.Path]::GetPathRoot($fullPath).TrimEnd("\").TrimEnd(":").ToLowerInvariant()
    $relative = $fullPath.Substring($fullPath.IndexOf(":") + 1).Replace("\", "/")
    return "/mnt/$drive$relative"
}

function Get-PubspecVersion {
    foreach ($line in [System.IO.File]::ReadAllLines((Join-Path $ProjectRoot "pubspec.yaml"))) {
        if ($line -match "^version:\s*([^\s#]+)") {
            return ($Matches[1] -split "\+")[0]
        }
    }

    throw "Unable to read version from pubspec.yaml."
}

function Find-Adb {
    param([string]$AndroidSdk)

    $candidates = @($Adb)
    $command = Get-Command "adb.exe" -ErrorAction SilentlyContinue
    if ($command) {
        $candidates += $command.Source
    }

    if ($AndroidSdk) {
        $candidates += Join-Path $AndroidSdk "platform-tools\adb.exe"
    }

    foreach ($candidate in $candidates) {
        $sdkAdb = Resolve-FullPath $candidate
        if ($sdkAdb -and (Test-Path -LiteralPath $sdkAdb)) {
            return $sdkAdb
        }
    }

    throw "adb.exe not found. Install Android platform-tools or use -Adb <path>."
}

function Add-GitSafeDirectory {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    $count = 0
    if ($env:GIT_CONFIG_COUNT -match '^\d+$') {
        $count = [int]$Matches[0]
    }

    Set-Item -Path "env:GIT_CONFIG_KEY_$count" -Value "safe.directory"
    Set-Item -Path "env:GIT_CONFIG_VALUE_$count" -Value ($Path -replace '\\', '/')
    $env:GIT_CONFIG_COUNT = ($count + 1).ToString()
}

try {
    if ($Debug) {
        $BuildMode = "debug"
    } else {
        $BuildMode = "release"
    }

    Write-Step "Preparing Burrow build ($BuildMode)"
    Write-Host "Project: $ProjectRoot"

    $oauthFile = Join-Path $ProjectRoot "lib\secrets\google_oauth.dart"
    $oauthTemplate = Join-Path $ProjectRoot "lib\secrets\google_oauth.example.dart"
    if (-not (Test-Path -LiteralPath $oauthFile)) {
        if (-not (Test-Path -LiteralPath $oauthTemplate)) {
            throw "Missing lib/secrets/google_oauth.dart and its example template."
        }

        Copy-Item -LiteralPath $oauthTemplate -Destination $oauthFile
        Write-Host "Created lib/secrets/google_oauth.dart from the bundled template."
    }

    $env:CI = "true"
    $env:FLUTTER_SUPPRESS_ANALYTICS = "true"
    $env:DART_TOOL_SUPPORTS_ANALYTICS = "false"

    $Flutter = Find-Flutter
    Add-GitSafeDirectory -Path (Split-Path -Parent (Split-Path -Parent $Flutter))
    $localProperties = Read-LocalProperties
    $Script:AndroidSdk = Find-AndroidSdk -Properties $localProperties
    $Ndk = Find-Ndk

    Write-Host "Flutter: $Flutter"
    if ($Script:AndroidSdk) {
        Write-Host "Android SDK: $Script:AndroidSdk"
    }
    if ($Ndk) {
        Write-Host "Android NDK: $Ndk"
        $env:ANDROID_NDK_HOME = $Ndk
    }

    Write-Step "Fetching Dart packages"
    Invoke-Checked -FilePath $Flutter -Arguments @("pub", "get")

    if ($RunChecks) {
        Write-Step "Running analyze and tests"
        $Dart = Join-Path (Split-Path -Parent (Split-Path -Parent $Flutter)) "bin\dart.bat"
        if (-not (Test-Path -LiteralPath $Dart)) {
            throw "dart.bat not found next to Flutter SDK: $Dart"
        }

        Invoke-Checked -FilePath $Dart -Arguments @("analyze")
        Invoke-Checked -FilePath $Flutter -Arguments @("test")
    }

    if ($SkipProot) {
        Write-Step "Checking bundled proot binaries"
        if (-not (Test-ProotArtifacts)) {
            throw "proot binaries are incomplete. Run tool/build_proot.sh or omit -SkipProot."
        }
        Write-Host "Using existing proot binaries."
    } else {
        Write-Step "Building proot for $($Abi -join ', ')"
        $bash = Get-Command "bash.exe" -ErrorAction SilentlyContinue

        if (-not $bash -or -not $Ndk) {
            if (Test-ProotArtifacts) {
                Write-Warning "bash.exe or Android NDK is unavailable; using existing proot binaries."
            } else {
                throw "Cannot build proot: bash.exe and Android NDK are required, and no existing binaries were found."
            }
        } else {
            $isWslBash = $bash.Source -eq (Join-Path $env:SystemRoot "System32\bash.exe")
            try {
                if ($isWslBash) {
                    $wslProject = Convert-ToWslPath $ProjectRoot
                    $wslNdk = Convert-ToWslPath $Ndk
                    $abiArguments = ($Abi | ForEach-Object { "'$_'" }) -join " "
                    & $bash.Source -c "set -euo pipefail; cd '$wslProject'; ANDROID_NDK_HOME='$wslNdk' ./tool/build_proot.sh $abiArguments"
                } else {
                    & $bash.Source "./tool/build_proot.sh" @Abi
                }

                if ($LASTEXITCODE -ne 0) {
                    throw "tool/build_proot.sh failed with exit code $LASTEXITCODE."
                }
            } catch {
                if (Test-ProotArtifacts) {
                    Write-Warning "proot rebuild failed; using existing binaries. Error: $($_.Exception.Message)"
                } else {
                    throw
                }
            }

            if (-not (Test-ProotArtifacts)) {
                throw "proot build did not produce complete binaries for $($Abi -join ', ')."
            }
        }
    }

    Write-Step "Building split APKs"
    $targetPlatforms = $Abi | ForEach-Object {
        if ($_ -eq "arm64-v8a") { "android-arm64" } else { "android-x64" }
    } | Select-Object -Unique
    $buildArguments = @(
        "build",
        "apk",
        "--$BuildMode",
        "--split-per-abi",
        "--target-platform=$($targetPlatforms -join ',')"
    )
    Invoke-Checked -FilePath $Flutter -Arguments $buildArguments

    $version = Get-PubspecVersion
    $dist = Join-Path $ProjectRoot "dist"
    New-Item -ItemType Directory -Path $dist -Force | Out-Null

    $apks = @()
    foreach ($target in $Abi) {
        $source = Join-Path $ProjectRoot "build\app\outputs\flutter-apk\app-$target-$BuildMode.apk"
        if (-not (Test-Path -LiteralPath $source)) {
            throw "Expected APK was not produced: $source"
        }

        $destination = Join-Path $dist "Burrow-$version-$target.apk"
        Copy-Item -LiteralPath $source -Destination $destination -Force
        $apks += (Get-Item -LiteralPath $destination)
    }

    Write-Step "Build complete"
    foreach ($apk in $apks) {
        $sizeMb = [Math]::Round($apk.Length / 1MB, 1)
        Write-Host "$($apk.FullName) ($sizeMb MB)"
    }

    if ($Install) {
        Write-Step "Installing arm64 APK"
        $arm64Apk = $apks | Where-Object { $_.Name.EndsWith("arm64-v8a.apk") } | Select-Object -First 1
        if (-not $arm64Apk) {
            throw "Cannot install: arm64-v8a APK was not built."
        }

        $adb = Find-Adb -AndroidSdk $Script:AndroidSdk
        $devicesOutput = & $adb "devices"
        if ($LASTEXITCODE -ne 0) {
            throw "adb devices failed with exit code $LASTEXITCODE."
        }

        $devices = @($devicesOutput | Where-Object { $_ -match "^\S+\tdevice\s*$" })
        if ($devices.Count -eq 0) {
            throw "No Android device is connected and authorized."
        }

        if (-not [string]::IsNullOrWhiteSpace($Serial)) {
            $selected = @($devices | Where-Object { ($_ -split "`t")[0] -eq $Serial })
            if ($selected.Count -eq 0) {
                throw "Android device '$Serial' is not connected and authorized."
            }

            $serial = $Serial
        } elseif ($devices.Count -gt 1) {
            throw "Multiple Android devices are connected. Connect only one device, or run adb install manually."
        } else {
            $serial = ($devices[0] -split "`t")[0]
        }
        Invoke-Checked -FilePath $adb -Arguments @("-s", $serial, "install", "-r", $arm64Apk.FullName)
        Write-Host "Installed to $serial."
    }
} finally {
    Pop-Location
}
