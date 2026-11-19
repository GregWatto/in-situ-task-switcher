[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$Version,

    [Parameter(Mandatory)]
    [string]$IsccPath
)

$ErrorActionPreference = 'Stop'
$compiler = (Resolve-Path -LiteralPath $IsccPath).Path
$compilerDir = Split-Path -Parent $compiler
$repoRoot = Split-Path -Parent $PSScriptRoot
$dist = (New-Item -ItemType Directory -Path (Join-Path $repoRoot 'dist') -Force).FullName

$runtimeVersion = '2.0.31'
$runtimeHash = 'CA1A595ACA4528755D8D4CD7FED23D497A37BD9A0B6892072612D68DEE1BD00A'
$archiveName = "AutoHotkey_${runtimeVersion}.zip"
$archive = Join-Path $dist $archiveName
if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) {
    $uri = "https://github.com/AutoHotkey/AutoHotkey/releases/download/v$runtimeVersion/$archiveName"
    Invoke-WebRequest -Uri $uri -OutFile $archive
}
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -cne $runtimeHash) {
    throw "The AutoHotkey archive did not match the published SHA-256. Replace $archive with the official archive."
}

$runtimeDir = (New-Item -ItemType Directory -Path (Join-Path $dist "AutoHotkey-$runtimeVersion") -Force).FullName
$zip = [System.IO.Compression.ZipFile]::OpenRead($archive)
try {
    foreach ($name in 'AutoHotkey64.exe', 'license.txt') {
        $entry = $zip.GetEntry($name)
        if ($null -eq $entry) { throw "The AutoHotkey archive is missing $name." }
        $target = Join-Path $runtimeDir $name
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
    }
} finally {
    $zip.Dispose()
}

$installerScript = Join-Path $PSScriptRoot 'InSitu.iss'
& $compiler "/DAppVersion=$Version" "/DRuntimeDir=$runtimeDir" "/DCompilerDir=$compilerDir" $installerScript
if ($LASTEXITCODE -ne 0) { throw "Inno Setup exited with code $LASTEXITCODE." }
