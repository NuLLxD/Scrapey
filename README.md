# SCRAPEY

# What is it?

Built for educational purposes to explore web scraping this tool scrapes cijapanese.com and archives videos locally for offline viewing. Supports Windows and Linux.

This tool was built with powershell and uses [yt-dlp](https://github.com/yt-dlp/yt-dlp) as an intermediary to download videos.

# How does it work?

Running Scrapey will parse the entire webpages catalog pulled from their api and stored in content.json, extract the relevant metadata and request from their cdn the appropriate video and subtitles. The script will automatically sort the video and subtitle pairs into their own folders.

This script supports using a cookies.txt file with a valid session id token as authentication for paid lessons otherwise this tool will only download free lessons.

# Usage

Git clone or download the repo
Start a powershell instance with elevated priveleges
Navigate to the script directory
Run the script
