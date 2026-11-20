[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [version]$InstalledVersion,

    [Parameter(Mandatory)]
    [int]$AppProcessId,

    [Parameter(Mandatory)]
    [ValidateSet('Default', 'AltTab')]
    [string]$Mode
)

$ErrorActionPreference = 'Stop'
$repository = 'GregWatto/in-situ-task-switcher'
$tempDir = $null

try {
    $app = Get-Process -Id $AppProcessId
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$repository/releases/latest" -TimeoutSec 15
    if ($release.draft -or $release.prerelease -or $release.tag_name -cnotmatch '^v(\d+\.\d+\.\d+)$') {
        throw 'GitHub did not return a stable In Situ release.'
    }

    $latestVersion = [version]$Matches[1]
    if ($latestVersion -le $InstalledVersion) { exit 0 }

    $name = "InSitu-Setup-$latestVersion-x64.exe"
    $url = "https://github.com/$repository/releases/download/$($release.tag_name)/$name"
    $assets = @($release.assets | Where-Object {
        $_.name -ceq $name -and $_.state -ceq 'uploaded' -and $_.browser_download_url -ceq $url
    })
    if ($assets.Count -ne 1 -or $assets[0].digest -cnotmatch '^sha256:([a-f0-9]{64})$') {
        throw 'The release does not contain a verifiable Windows installer.'
    }
    $expectedHash = $Matches[1]

    $tempDir = Join-Path ([IO.Path]::GetTempPath()) ("InSitu-Update-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempDir | Out-Null
    $setup = Join-Path $tempDir $name
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $setup -TimeoutSec 120
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $download = [IO.File]::OpenRead($setup)
        try {
            $actualHash = [BitConverter]::ToString($sha256.ComputeHash($download)).Replace('-', '')
        } finally {
            $download.Dispose()
        }
    } finally {
        $sha256.Dispose()
    }
    if ($actualHash -ne $expectedHash) {
        throw 'The installer download did not match the release SHA-256.'
    }

    # A user exit or replacement during the download cancels this attempt.
    if ($app.HasExited) { exit 1 }

    $setupArgs = '/VERYSILENT /SUPPRESSMSGBOXES /SP- /NORESTART /NOCLOSEAPPLICATIONS /DIR="{0}"' -f $PSScriptRoot
    try {
        $installer = Start-Process -FilePath $setup -ArgumentList $setupArgs -WindowStyle Hidden -PassThru -Wait
        if ($installer.ExitCode -ne 0) {
            throw "In Situ Setup exited with code $($installer.ExitCode)."
        }
    } finally {
        # Setup stops the previous instance. Restore its shortcut mode even if setup fails.
        if ($app.HasExited) {
            $scriptPath = Join-Path $PSScriptRoot 'WindowSwitcher.ahk'
            $appArgs = '/CP65001 "{0}"' -f $scriptPath
            if ($Mode -eq 'AltTab') { $appArgs += ' --alt-tab' }
            $appArgs += ' --after-update'
            Start-Process -FilePath (Join-Path $PSScriptRoot 'runtime\AutoHotkey64.exe') `
                -ArgumentList $appArgs -WorkingDirectory $PSScriptRoot -WindowStyle Hidden
        }
    }
} catch {
    Write-Error -ErrorRecord $_ -ErrorAction Continue
    exit 1
} finally {
    if ($tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
}
