# Publishes Bardo self-contained for one architecture and wraps it in its installer.
#
#   windows/installer/build-installer.ps1 -Arch x64 -Output dist
#
# With -Published, it wraps a folder already published instead of publishing again.
#
# The version comes from project.yml, the one place the macOS app keeps it too.
param(
    [Parameter(Mandatory)][ValidateSet("x64", "arm64")][string]$Arch,
    [string]$Output = "dist",
    [string]$Published
)
$ErrorActionPreference = "Stop"
$root = Resolve-Path (Join-Path $PSScriptRoot "../..")
$version = (Select-String -Path (Join-Path $root "project.yml") -Pattern "MARKETING_VERSION:\s*(\S+)").Matches[0].Groups[1].Value
$platform = if ($Arch -eq "arm64") { "ARM64" } else { "x64" }
New-Item -ItemType Directory -Force -Path $Output | Out-Null

if ($Published) {
    $publish = Resolve-Path $Published
} else {
    $publish = Join-Path $root "windows/publish/Bardo-win-$Arch"
    dotnet publish (Join-Path $root "windows/src/Bardo.App") `
        --configuration Release --runtime "win-$Arch" --self-contained `
        -p:Platform=$platform -p:Version=$version --output $publish
    if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed" }
}

$iscc = "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe"
if (-not (Test-Path $iscc)) {
    choco install innosetup --yes --no-progress | Out-Null
}
& $iscc "/DAppVersion=$version" "/DArch=$Arch" "/DSourceDir=$publish" "/DOutputDir=$(Resolve-Path $Output)" (Join-Path $PSScriptRoot "Bardo.iss")
if ($LASTEXITCODE -ne 0) { throw "Inno Setup failed" }

$installer = Join-Path (Resolve-Path $Output) "Bardo-$version-Setup-$Arch.exe"
$hash = (Get-FileHash $installer -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content -Path "$installer.sha256" -Value "$hash  $(Split-Path $installer -Leaf)" -NoNewline -Encoding ascii
Write-Output $installer
