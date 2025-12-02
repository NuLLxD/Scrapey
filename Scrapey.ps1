# --- Global Configuration ---
$JsonFile      = Join-Path $PWD "content.json"
$OutputFile    = Join-Path $PWD "output.txt"
$CookiesPath   = Join-Path $PWD "cookies.txt"
$BaseCdnUrl    = "https://cij-edge.b-cdn.net/prod/hls"
$RefererUrl    = "https://cijapanese.com/"

# Trap for clean output on exit
trap { exit 0 }

# OS Detection
$IsLinuxSystem = $IsLinux -or ($PSVersionTable.Platform -eq "Unix")
$BinaryName    = if ($IsLinuxSystem) { "yt-dlp_linux" } else { "yt-dlp.exe" }
$BinaryPath    = Join-Path $PWD $BinaryName

# --- Helper Functions ---

function Get-YtDlpBinary {
    if (-not (Test-Path $BinaryPath)) {
        Write-Host "Downloading yt-dlp..." -ForegroundColor Yellow
        $Url = "https://github.com/yt-dlp/yt-dlp/releases/latest/download/$BinaryName"
        Invoke-WebRequest -Uri $Url -OutFile $BinaryPath
    }
    if ($IsLinuxSystem) { try { chmod +x $BinaryPath } catch {} }
    return $BinaryPath
}

function Get-WebHeaders {
    $Headers = @{ "Referer" = $global:RefererUrl }
    if (Test-Path $CookiesPath) {
        $C = @()
        foreach ($Line in Get-Content $CookiesPath) {
            if ($Line.StartsWith("#") -or $Line.Length -lt 5) { continue }
            $Parts = $Line -split "`t"
            if ($Parts.Count -ge 7) { $C += "$($Parts[5])=$($Parts[6])" }
        }
        $Headers["Cookie"] = ($C -join "; ")
    }
    return $Headers
}

function Get-SanitizedName {
    param([string]$Name)
    return $Name -replace '[\\/*?:"<>|]', "" -replace '\s+', " "
}

function Get-LocalContent {
    if (-not (Test-Path $JsonFile)) { Write-Error "content.json not found!"; exit }
    try {
        $Raw = Get-Content -Path $JsonFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($Raw.data.modules) { return $Raw.data.modules }
        if ($Raw.data) { return $Raw.data }
        return $Raw 
    } catch { Write-Error "Error parsing content.json."; exit }
}

function Add-ToOutput {
    param([string]$Id)
    $Id | Out-File -FilePath $OutputFile -Append -Encoding ASCII
}

function Invoke-Download {
    param([string]$Url, [string]$DestFileTemplate, [string]$Tool, [string]$Cookies)
    
    $ArgsList = @(
        "-o", "$DestFileTemplate",
        "--concurrent-fragments", "4",
        "--referer", $global:RefererUrl,
        "--no-warn",
        $Url
    )
    if (Test-Path $Cookies) { $ArgsList += "--cookies", $Cookies }

    & $Tool @ArgsList
    
    return ($LASTEXITCODE -eq 0)
}

# --- Main Execution ---

Write-Host "=== CIJapanese Library Manager ===" -ForegroundColor Cyan

# First Run
$Tool = Get-YtDlpBinary
$Headers = Get-WebHeaders
$VideoList = Get-LocalContent
$CompletedIds = if (Test-Path $OutputFile) { @(Get-Content $OutputFile) } else { @() }

Write-Host "Loaded $( $VideoList.Count ) videos." -ForegroundColor Green
Write-Host "Completed: $( $CompletedIds.Count )" -ForegroundColor Green

# Paths
$BaseSaveDir = Read-Host "Enter Save Directory (Press Enter for 'Downloads')"
if ([string]::IsNullOrWhiteSpace($BaseSaveDir)) { $BaseSaveDir = Join-Path $PWD "Downloads" }
if (-not (Test-Path $BaseSaveDir)) { New-Item -ItemType Directory -Path $BaseSaveDir | Out-Null }

Write-Host "`n=== Starting Queue ===" -ForegroundColor Yellow
Write-Host "Working in: $BaseSaveDir" -ForegroundColor Gray

foreach ($Item in $VideoList) {
    # --- Metadata ---
    $Id = "$($Item.id)"
    if (-not $Id) { continue }
    if ($CompletedIds -contains $Id) { continue }

    $TitleRaw = if ($Item.plan.titleEN) { $Item.plan.titleEN } elseif ($Item.titleEN) { $Item.titleEN } else { "Video_$Id" }
    $Level    = if ($Item.level) { $Item.level } else { "Uncategorized" }
    $BunnyId  = if ($Item.plan.bunnyId) { $Item.plan.bunnyId } elseif ($Item.bunnyId) { $Item.bunnyId } else { $null }
    
    if (-not $BunnyId) { continue } 

    $SafeTitle = Get-SanitizedName -Name $TitleRaw
    $SafeLevel = Get-SanitizedName -Name $Level

    # --- Path Logic ---
    $LevelDir    = Join-Path $BaseSaveDir $SafeLevel
    $NewVideoDir = Join-Path $LevelDir $SafeTitle
    $OldVideoDir = Join-Path $BaseSaveDir $SafeTitle

    # Migrate Old -> New
    if ((Test-Path $OldVideoDir) -and -not (Test-Path $NewVideoDir)) {
        Write-Host "Migrating '$SafeTitle' to '$SafeLevel'..." -ForegroundColor Magenta
        if (-not (Test-Path $LevelDir)) { New-Item -ItemType Directory -Path $LevelDir | Out-Null }
        Move-Item -Path $OldVideoDir -Destination $LevelDir
    }

    # Verify File Existence
    if (-not (Test-Path $NewVideoDir)) { New-Item -ItemType Directory -Path $NewVideoDir | Out-Null }

    $AlreadyExists = $false
    foreach ($Ext in @(".mp4", ".mkv", ".webm")) {
        if (Test-Path (Join-Path $NewVideoDir "$SafeTitle$Ext")) {
            $AlreadyExists = $true; break
        }
    }

    if ($AlreadyExists) {
        Write-Host "Found Existing: [$SafeLevel] $SafeTitle" -ForegroundColor Green
        Add-ToOutput -Id $Id
        continue
    }

    # Download
    Write-Host "Downloading: [$SafeLevel] $SafeTitle" -ForegroundColor Cyan
    
    $StreamUrl = "$BaseCdnUrl/$BunnyId/playlist.m3u8"
    $SubUrl    = "$BaseCdnUrl/$BunnyId/subtitles.vtt"
    $Template  = Join-Path $NewVideoDir "$SafeTitle.%(ext)s"

    $Success = Invoke-Download -Url $StreamUrl -DestFileTemplate $Template -Tool $Tool -Cookies $CookiesPath

    if ($Success) {
        Add-ToOutput -Id $Id
        
        # Subtitles
        $SubPath = Join-Path $NewVideoDir "$SafeTitle.vtt"
        if (-not (Test-Path $SubPath)) {
            try {
                Invoke-WebRequest -Uri $SubUrl -OutFile $SubPath -Headers $Headers -UserAgent "Mozilla/5.0" -ErrorAction Stop
                Write-Host "    + Subtitles" -ForegroundColor Green
            } catch {}
        }
    }
}

Write-Host "`nAll tasks complete." -ForegroundColor Green