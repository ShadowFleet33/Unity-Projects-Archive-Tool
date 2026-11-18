# ------------------------------------------------------------
# Unity Projects Dummy Data Generator
# Creates test Unity projects with dummy data for testing
# ------------------------------------------------------------

param(
    # Optional: generate projects somewhere other than the script folder
    [string]$TargetDir
)

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir = if ($TargetDir) { $TargetDir } else { $scriptDir }

$unityVersions = @("2021.3.33f1", "2022.3.20f1", "2023.2.5f1", "6000.0.23f1")
$pipelines = @(
    @{ Name = "Built-in"; Package = $null }
    @{ Name = "URP"; Package = "com.unity.render-pipelines.universal" }
    @{ Name = "HDRP"; Package = "com.unity.render-pipelines.high-definition" }
)

function Show-Header {

    Clear-Host

    Write-Host "=================================================" -ForegroundColor Cyan
    Write-Host " Unity Projects Dummy Data Generator" -ForegroundColor Cyan
    Write-Host " Root directory: $rootDir" -ForegroundColor DarkGray
    Write-Host "================================================="
}

# ------------------------------------------------------------
# File helpers
# ------------------------------------------------------------

# Sparse-style file (zero filled, instant). Used for Library cache data.
function New-DummyFile {

    param(
        [string]$Path,
        [int64]$SizeBytes
    )

    $fs = [System.IO.File]::Create($Path)
    $fs.SetLength($SizeBytes)
    $fs.Close()
}

# Random bytes: behaves like already-compressed data (PNG, MP4, OGG...)
function New-RandomFile {

    param(
        [string]$Path,
        [int64]$SizeBytes
    )

    $buffer = [byte[]]::new([Math]::Min(1MB, [Math]::Max(1, $SizeBytes)))
    $fs = [System.IO.File]::Create($Path)

    try {
        $remaining = $SizeBytes
        while ($remaining -gt 0) {
            [System.Security.Cryptography.RandomNumberGenerator]::Fill($buffer)
            $count = [int][Math]::Min($buffer.Length, $remaining)
            $fs.Write($buffer, 0, $count)
            $remaining -= $count
        }
    }
    finally {
        $fs.Close()
    }
}

# Text in Unity YAML style: compresses well (scenes, prefabs, materials)
function New-TextFile {

    param(
        [string]$Path,
        [int64]$SizeBytes
    )

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("%YAML 1.1")
    [void]$sb.AppendLine("%TAG !u! tag:unity3d.com,2011:")

    $writer = [System.IO.StreamWriter]::new($Path, $false, [System.Text.UTF8Encoding]::new($false))

    try {
        $writer.Write($sb.ToString())
        $written = $sb.Length
        $id = 0

        while ($written -lt $SizeBytes) {
            $id++
            $block = "--- !u!1 &$(Get-Random)`nGameObject:`n  m_Name: Object_$id`n  m_Layer: $($id % 32)`n  m_IsActive: 1`n  m_LocalPosition: {x: $(Get-Random -Maximum 100), y: 0, z: $(Get-Random -Maximum 100)}`n"
            $writer.Write($block)
            $written += $block.Length
        }
    }
    finally {
        $writer.Close()
    }
}

function New-MetaFile {

    param([string]$AssetPath)

    $guid = [guid]::NewGuid().ToString("N")
    Set-Content -LiteralPath "$AssetPath.meta" -Value "fileFormatVersion: 2`nguid: $guid" -Encoding utf8
}

function New-AssetFolder {

    param([string]$Path)

    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    New-MetaFile $Path
}

# ------------------------------------------------------------
# Generate Test Projects
# ------------------------------------------------------------
function Set-TestProjects {

    try {
        $projectCount = [int](Read-Host "How many projects to generate?")
        $minGB = [double](Read-Host "Minimum project size (GB, decimals allowed e.g. 0.2)")
        $maxGB = [double](Read-Host "Maximum project size (GB)")
    }
    catch {
        Write-Host "Invalid number." -ForegroundColor Red
        return
    }

    if ($maxGB -lt $minGB) { $maxGB = $minGB }

    $created = 0
    $index = 1

    while ($created -lt $projectCount) {

        # Skip names that already exist so repeated runs add new projects
        $projectName = "TEST_UnityProject_{0:D3}" -f $index
        $index++
        $projectPath = Join-Path $rootDir $projectName
        if (Test-Path -LiteralPath $projectPath) { continue }

        Write-Host ""
        Write-Host "Creating project: $projectName" -ForegroundColor Yellow

        $assetsPath = Join-Path $projectPath "Assets"
        $libraryPath = Join-Path $projectPath "Library"
        $settingsPath = Join-Path $projectPath "ProjectSettings"
        $packagesPath = Join-Path $projectPath "Packages"

        foreach ($dir in @($assetsPath, $libraryPath, $settingsPath, $packagesPath)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }

        # Project metadata the archive tool reads
        $version = $unityVersions | Get-Random
        $pipeline = $pipelines | Get-Random
        Set-Content -LiteralPath (Join-Path $settingsPath "ProjectVersion.txt") -Value "m_EditorVersion: $version" -Encoding utf8
        Set-Content -LiteralPath (Join-Path $settingsPath "ProjectSettings.asset") -Value "PlayerSettings:`n  productName: $projectName" -Encoding utf8

        $deps = [ordered]@{ "com.unity.textmeshpro" = "3.0.6"; "com.unity.modules.audio" = "1.0.0"; "com.unity.modules.physics" = "1.0.0" }
        if ($pipeline.Package) { $deps[$pipeline.Package] = "14.0.9" }
        @{ dependencies = $deps } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $packagesPath "manifest.json") -Encoding utf8

        # Realistic Assets structure
        $folders = @("Scripts", "Materials", "Textures", "Audio", "Video", "Scenes", "Prefabs", "Plugins")
        foreach ($folder in $folders) { New-AssetFolder (Join-Path $assetsPath $folder) }

        $projectSizeBytes = [int64]((Get-Random -Minimum $minGB -Maximum ($maxGB + 0.0001)) * 1GB)

        # 30% Assets, 70% Library (cache)
        $assetsSize = [int64][Math]::Floor($projectSizeBytes * 0.3)
        $librarySize = $projectSizeBytes - $assetsSize

        Write-Host "Target size: $([Math]::Round($projectSizeBytes / 1GB, 2)) GB  (Unity $version, $($pipeline.Name))"

        # Scripts (small text)
        for ($s = 1; $s -le 5; $s++) {
            $scriptFile = Join-Path $assetsPath "Scripts\Script$s.cs"
            Set-Content -LiteralPath $scriptFile -Value "using UnityEngine;`npublic class Script$s : MonoBehaviour { void Update() { } }" -Encoding utf8
            New-MetaFile $scriptFile
        }

        # Incompressible media (random bytes) vs compressible YAML text
        $assetFiles = @(
            @{ Path = "Textures\Albedo.png"; Share = 0.35; Kind = "Random" }
            @{ Path = "Audio\Music.ogg"; Share = 0.15; Kind = "Random" }
            @{ Path = "Video\Intro.mp4"; Share = 0.15; Kind = "Random" }
            @{ Path = "Plugins\Native.dll"; Share = 0.05; Kind = "Random" }
            @{ Path = "Scenes\Main.unity"; Share = 0.15; Kind = "Text" }
            @{ Path = "Prefabs\Player.prefab"; Share = 0.10; Kind = "Text" }
            @{ Path = "Materials\Ground.mat"; Share = 0.05; Kind = "Text" }
        )

        foreach ($asset in $assetFiles) {
            $filePath = Join-Path $assetsPath $asset.Path
            $size = [int64]($assetsSize * $asset.Share)
            if ($asset.Kind -eq "Random") { New-RandomFile $filePath $size } else { New-TextFile $filePath $size }
            New-MetaFile $filePath
        }

        # Loose file at the Assets root (older tool versions dropped these)
        Set-Content -LiteralPath (Join-Path $assetsPath "README.txt") -Value "Dummy project $projectName" -Encoding utf8
        New-MetaFile (Join-Path $assetsPath "README.txt")

        # Library files (cache)
        New-DummyFile (Join-Path $libraryPath "dummy_library.bin") $librarySize

        Write-Host "Created dummy data." -ForegroundColor Green
        $created++
    }

    Write-Host ""
    Write-Host "Dummy projects generated successfully." -ForegroundColor Green
}

# ------------------------------------------------------------
# Delete Test Projects
# ------------------------------------------------------------
function Remove-TestProjects {

    Write-Host ""
    Write-Host "Searching for generated test projects..." -ForegroundColor Yellow

    $projects = @(Get-ChildItem -LiteralPath $rootDir -Directory |
        Where-Object { $_.Name -like "TEST_UnityProject_*" })

    if ($projects.Count -eq 0) {

        Write-Host "No generated test projects found." -ForegroundColor Red
        return
    }

    $confirm = (Read-Host "Delete ALL $($projects.Count) generated test projects? [y/N]").ToLower()

    if ($confirm -notin @("y", "yes")) {
        Write-Host "Operation cancelled."
        return
    }

    foreach ($p in $projects) {

        Write-Host "Deleting $($p.Name)" -ForegroundColor DarkYellow
        Remove-Item -LiteralPath $p.FullName -Recurse -Force
    }

    Write-Host ""
    Write-Host "All generated test projects deleted." -ForegroundColor Green
}

function Start-ArchiveTool {

    $toolPath = Join-Path $scriptDir "UnityProjectsArchiveTool.ps1"

    if (!(Test-Path -LiteralPath $toolPath)) {

        Write-Host ""
        Write-Host "Archive tool not found!" -ForegroundColor Red
        Write-Host "Expected file:" -ForegroundColor Yellow
        Write-Host $toolPath
        return
    }

    Write-Host ""
    Write-Host "Launching UnityProjectsArchiveTool..." -ForegroundColor Green

    # The archive tool needs PowerShell 7+
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        & $toolPath -RootPath $rootDir
    }
    elseif (Get-Command pwsh -ErrorAction SilentlyContinue) {
        pwsh -NoProfile -File $toolPath -RootPath $rootDir
    }
    else {
        Write-Host "PowerShell 7 (pwsh) is required for the archive tool: winget install Microsoft.PowerShell" -ForegroundColor Red
    }
}

# ------------------------------------------------------------
# Menu
# ------------------------------------------------------------
function Show-Menu {

    Write-Host ""
    Write-Host "1 - Generate Test Projects" -ForegroundColor Cyan
    Write-Host "2 - Delete Generated Projects" -ForegroundColor Yellow
    Write-Host "3 - Run Archive Tool" -ForegroundColor Green
    Write-Host "4 - Exit" -ForegroundColor DarkGray
}

# ------------------------------------------------------------
# Main Loop
# ------------------------------------------------------------
$running = $true

while ($running) {

    Show-Header
    Show-Menu

    $choice = Read-Host "Select option"

    switch ($choice) {

        "1" { Set-TestProjects }

        "2" { Remove-TestProjects }

        "3" { Start-ArchiveTool }

        "4" { $running = $false }

        default {
            Write-Host "Invalid selection." -ForegroundColor Red
        }
    }

    if ($running) { Read-Host "`nPress Enter to continue" | Out-Null }
}
