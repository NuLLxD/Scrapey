<#
.SYNOPSIS
    CIJapanese Library Manager (Robust Filename Fix)
.DESCRIPTION
    1. OUTPUT: Uses yt-dlp's native progress bar.
    2. RESUME: Checks output.txt and disk state.
    3. MIGRATE: Auto-moves old folders.
    4. ROBUST: Handles illegal characters in titles without crashing.
#>

# --- Global Configuration ---
$JsonFile      = Join-Path $PWD "content.json"
$OutputFile    = Join-Path $PWD "output.txt"
$CookiesPath   = Join-Path $PWD "cookies.txt"
$BaseCdnUrl    = "https://cij-edge.b-cdn.net/prod/hls"
$RefererUrl    = "https://cijapanese.com/"

# Silent Exit on Ctrl+C
[console]::TreatControlCAsInput = $false 
trap { 
    Write-Host "`n[!] Interrupted." -ForegroundColor Yellow
    exit 0
}

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
    $Clean = $Name -replace '[\\/*?:"<>|]', ""
    $Clean = $Clean -replace '\s+', " "
    $Clean = $Clean.Trim().TrimEnd('.')
    return $Clean
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
    param([string]$Url, [string]$DestFile, [string]$Tool, [string]$Cookies)
    
    $ArgsList = @(
        "-o", "$DestFile", 
        "--concurrent-fragments", "4",
        "--no-overwrites",
        "--no-warn",
        "--referer", $global:RefererUrl,
        $Url
    )
    if (Test-Path $Cookies) { $ArgsList += "--cookies", $Cookies }

    & $Tool @ArgsList
    
    return ($LASTEXITCODE -eq 0)
}

# --- Main Execution ---

Write-Host "=== CIJapanese Library Manager ===" -ForegroundColor Cyan

# Init
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
    
    # Fast skip if known complete
    if ($CompletedIds -contains $Id) { continue }

    $TitleRaw = if ($Item.plan.titleEN) { $Item.plan.titleEN } elseif ($Item.titleEN) { $Item.titleEN } else { "Video_$Id" }
    $Level    = if ($Item.level) { $Item.level } else { "Uncategorized" }
    $BunnyId  = if ($Item.plan.bunnyId) { $Item.plan.bunnyId } elseif ($Item.bunnyId) { $Item.bunnyId } else { $null }
    
    if (-not $BunnyId) { continue } 

    $SafeTitle = Get-SanitizedName -Name $TitleRaw
    $SafeLevel = Get-SanitizedName -Name $Level

    try {
        # --- Path Resolution & Migration ---
        $LevelDir    = Join-Path $BaseSaveDir $SafeLevel
        $NewVideoDir = Join-Path $LevelDir $SafeTitle 
        $OldVideoDir = Join-Path $BaseSaveDir $SafeTitle 

        # Migrate Old -> New
        if ((Test-Path $OldVideoDir) -and -not (Test-Path $NewVideoDir)) {
            Write-Host "Migrating '$SafeTitle'..." -ForegroundColor Magenta
            if (-not (Test-Path $LevelDir)) { New-Item -ItemType Directory -Path $LevelDir | Out-Null }
            Move-Item -Path $OldVideoDir -Destination $LevelDir -ErrorAction Stop
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
            # Silent update of output.txt if found on disk
            Add-ToOutput -Id $Id
            continue
        }

        # Download
        Write-Host "Processing: $SafeTitle" -ForegroundColor Cyan
        
        $StreamUrl = "$BaseCdnUrl/$BunnyId/playlist.m3u8"
        $SubUrl    = "$BaseCdnUrl/$BunnyId/subtitles.vtt"
        $Template  = Join-Path $NewVideoDir "$SafeTitle.%(ext)s"

        $Success = Invoke-Download -Url $StreamUrl -DestFile $Template -Tool $Tool -Cookies $CookiesPath

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
    catch {
        Write-Warning "Skipping '$SafeTitle' due to file system error: $($_.Exception.Message)"
        continue
    }
}

Write-Host "`nAll tasks complete." -ForegroundColor Green