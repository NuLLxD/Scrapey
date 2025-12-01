# --- Global Configuration ---
$JsonFile      = Join-Path $PWD "content.json"
$CookiesPath   = Join-Path $PWD "cookies.txt"
$BaseCdnUrl    = "https://cij-edge.b-cdn.net/prod/hls"
$RefererUrl    = "https://cijapanese.com/"

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
    # Start with Cookies if available
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
    if (-not (Test-Path $JsonFile)) {
        Write-Error "content.json not found! Please place it next to the script."
        exit
    }
    try {
        $Raw = Get-Content -Path $JsonFile -Raw -Encoding UTF8 | ConvertFrom-Json
        # Check for nested 'data.modules' or just 'data' or root array
        if ($Raw.data.modules) { return $Raw.data.modules }
        if ($Raw.data) { return $Raw.data }
        return $Raw 
    }
    catch {
        Write-Error "Error reading content.json. Check format."
        exit
    }
}

function Invoke-Download {
    param([string]$Url, [string]$DestFile, [string]$Tool, [string]$Cookies)
    
    $ArgsList = @(
        "-o", "$DestFile", 
        "--concurrent-fragments", "4",
        "--no-overwrites",
        "--no-warn",
        "--referer", $global:RefererUrl, # <--- THE FIX for 403 Errors
        $Url
    )
    
    # Add cookies to yt-dlp if they exist
    if (Test-Path $Cookies) {
        $ArgsList += "--cookies", $Cookies
    }

    & $Tool @ArgsList
}

# --- Main Execution ---

Write-Host "=== CIJapanese Downloader ===" -ForegroundColor Cyan

# Setup
$Tool = Get-YtDlpBinary
$Headers = Get-WebHeaders

# Load JSON
$VideoList = Get-LocalContent
Write-Host "Loaded $( $VideoList.Count ) videos from content.json" -ForegroundColor Green

# Directory Setup
$BaseSaveDir = Read-Host "Enter Save Directory (Press Enter for current folder)"
if ([string]::IsNullOrWhiteSpace($BaseSaveDir)) { 
    $BaseSaveDir = Join-Path $PWD "Downloads" 
    Write-Host "Using default: $BaseSaveDir" -ForegroundColor Gray
}
if (-not (Test-Path $BaseSaveDir)) { New-Item -ItemType Directory -Path $BaseSaveDir | Out-Null }

Write-Host "`n=== Starting Batch ===" -ForegroundColor Yellow

# Processing Loop
foreach ($Item in $VideoList) {
    
    # --- Metadata Extraction ---
    $Id = $Item.id
    if (-not $Id) { continue }

    # Get Title (English preferred)
    $TitleRaw = "Video_$Id"
    if ($Item.plan.titleEN) { $TitleRaw = $Item.plan.titleEN }
    elseif ($Item.titleEN)  { $TitleRaw = $Item.titleEN }

    # Get Bunny ID
    $BunnyId = $null
    if ($Item.plan.bunnyId) { $BunnyId = $Item.plan.bunnyId }
    elseif ($Item.bunnyId)  { $BunnyId = $Item.bunnyId }

    if (-not $BunnyId) {
        Write-Warning "Skipping '$TitleRaw' (No BunnyID found)."
        continue
    }

    $SafeTitle = Get-SanitizedName -Name $TitleRaw
    Write-Host "Processing: $TitleRaw" -ForegroundColor Cyan
    
    # --- Folder Setup ---
    $VideoDir = Join-Path $BaseSaveDir $SafeTitle
    if (-not (Test-Path $VideoDir)) { New-Item -ItemType Directory -Path $VideoDir | Out-Null }

    # --- URL Construction ---
    $StreamUrl = "$BaseCdnUrl/$BunnyId/playlist.m3u8"
    $SubUrl    = "$BaseCdnUrl/$BunnyId/subtitles.vtt"

    # --- Execution ---
    
    # Download Video
    $VidPath = Join-Path $VideoDir "$SafeTitle.%(ext)s"
    
    # Pass the cookies file path to yt-dlp if it exists
    Invoke-Download -Url $StreamUrl -DestFile $VidPath -Tool $Tool -Cookies $CookiesPath

    # Download Subtitles
    $SubPath = Join-Path $VideoDir "$SafeTitle.vtt"
    if (-not (Test-Path $SubPath)) {
        Write-Host "    Fetching Subtitles..." -ForegroundColor Gray
        try {
            # Added Referer Header here too
            Invoke-WebRequest -Uri $SubUrl -OutFile $SubPath -Headers $Headers -UserAgent "Mozilla/5.0" -ErrorAction Stop
        } catch {
            # Suppress error if subtitles don't exist (common for some videos)
            Write-Host "    (No subtitles found)" -ForegroundColor DarkGray
        }
    }
}

Write-Host "`nAll tasks complete." -ForegroundColor Green