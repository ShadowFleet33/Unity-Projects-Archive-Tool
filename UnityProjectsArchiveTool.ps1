#Requires -Version 7.0
# ============================================================
# Unity Projects Archive Tool
# ============================================================

param(
    # Optional: override the projects root folder(s) for this session only
    [string[]]$RootPath
)

Set-StrictMode -Version Latest

$scriptDir = $PSScriptRoot
$ScriptVersion = @(0, 6, 1)
$ConfigPath = Join-Path $scriptDir "UnityArchiveTool.settings.json"

# ------------------------------------------------------------
# Static data: file categories, folder groups, presets, levels
# ------------------------------------------------------------
$CategoryExtensions = [ordered]@{
    "Scripts"        = @(".cs", ".asmdef", ".asmref", ".js", ".boo", ".rsp", ".uss", ".uxml", ".tss")
    "Shaders"        = @(".shader", ".shadergraph", ".shadersubgraph", ".hlsl", ".cginc", ".compute", ".glsl", ".raytrace", ".shadervariants")
    "Textures"       = @(".png", ".jpg", ".jpeg", ".tga", ".psd", ".psb", ".tif", ".tiff", ".exr", ".hdr", ".bmp", ".gif", ".iff", ".pict", ".dds", ".ktx", ".astc", ".svg")
    "Models"         = @(".fbx", ".obj", ".blend", ".dae", ".3ds", ".max", ".ma", ".mb", ".dxf", ".skp", ".c4d", ".lxo", ".gltf", ".glb", ".usd", ".usdz", ".abc")
    "Audio"          = @(".wav", ".mp3", ".ogg", ".aif", ".aiff", ".flac", ".mod", ".it", ".s3m", ".xm", ".m4a")
    "Video"          = @(".mp4", ".mov", ".webm", ".avi", ".m4v", ".mpg", ".mpeg", ".ogv", ".wmv", ".asf", ".dv", ".vp8")
    "Scenes"         = @(".unity")
    "Fonts"          = @(".ttf", ".otf", ".ttc", ".fon", ".fnt", ".woff", ".woff2")
    "Unity Packages" = @(".unitypackage")
    "Prefabs & Data" = @(".prefab", ".mat", ".asset", ".controller", ".anim", ".overridecontroller", ".physicmaterial", ".physicsmaterial2d",
        ".mask", ".playable", ".rendertexture", ".spriteatlas", ".spriteatlasv2", ".lighting", ".terrainlayer", ".mixer", ".flare",
        ".cubemap", ".guiskin", ".fontsettings", ".brush", ".signal", ".preset", ".inputactions", ".giparams", ".mesh")
}
$CategoryNames = @($CategoryExtensions.Keys) + "Other"

# Case-insensitive extension -> category lookup
$ExtensionCategory = @{}
foreach ($cat in $CategoryExtensions.Keys) {
    foreach ($ext in $CategoryExtensions[$cat]) { $ExtensionCategory[$ext] = $cat }
}

# Top-level folders under Assets that can be toggled as a group
$FolderGroups = [ordered]@{
    "Plugins & ThirdParty" = @("Plugins", "ThirdParty", "Third Party", "Extensions", "AssetStore", "Asset Store")
    "StreamingAssets"      = @("StreamingAssets")
    "Samples"              = @("Samples")
}

$Presets = [ordered]@{
    "Restorable"  = @{ Label = "Restorable project"; Description = "Assets + Packages + ProjectSettings - can be reopened in Unity"; Roots = @("Assets", "Packages", "ProjectSettings"); Only = $null }
    "AssetsOnly"  = @{ Label = "Assets only"; Description = "Only the Assets folder (plus extra folders)"; Roots = @("Assets"); Only = $null }
    "ScriptsOnly" = @{ Label = "Scripts only"; Description = "Only code and shader files from Assets"; Roots = @("Assets"); Only = @("Scripts", "Shaders") }
    "Custom"      = @{ Label = "Custom"; Description = "Pick which project folders to include"; Roots = $null; Only = $null }
}

$CompressionLevels = @(
    [pscustomobject]@{ Level = 3; Name = "Fast" }
    [pscustomobject]@{ Level = 5; Name = "Normal" }
    [pscustomobject]@{ Level = 7; Name = "Max" }
    [pscustomobject]@{ Level = 9; Name = "Ultra" }
)

# Session state
$script:ProjectCache = $null
$script:ProjectCacheTime = $null
$script:SevenZip = $null
# Duplicate detection: persistent hash cache per root, drive types, stats of the last run
$script:HashStores = @{}
$script:DriveMediaTypes = @{}
$script:LastHashStats = $null

# ============================================================
# Config
# ============================================================
function Get-DefaultConfig {
    [ordered]@{
        RootPaths        = @($scriptDir)
        OutputDir        = ""          # empty = <project's root>\_Archives
        SevenZipPath     = ""          # empty = auto-detect
        CompressionLevel = 7
        CleanupFolders   = @("Library", "Temp", "obj", "Logs")
        Archive          = [ordered]@{
            Preset          = "Restorable"
            CustomRoots     = @("Assets", "Packages", "ProjectSettings")
            ExcludedContent = @()
            ExtraFolders    = @()
            ExcludePatterns = @()
            IncludePatterns = @()
            SharedPool      = $false   # store files shared by several projects once, in _SharedAssets_*.7z
        }
        Dedup            = [ordered]@{
            MinBytes    = 1MB          # smaller files are ignored by duplicate detection
            TrustCopies = $true        # same name + size + modified time as a hashed file = same content (not read)
            HashThreads = 0            # 0 = auto (1 on hard drives, 4 on SSDs)
        }
    }
}

function Import-ToolConfig {

    $cfg = Get-DefaultConfig

    if (Test-Path -LiteralPath $ConfigPath) {
        try {
            $loaded = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json -AsHashtable

            foreach ($key in @($loaded.Keys)) {
                if ($key -in @("Archive", "Dedup") -and $loaded[$key] -is [System.Collections.IDictionary]) {
                    foreach ($subKey in @($loaded[$key].Keys)) { $cfg[$key][$subKey] = $loaded[$key][$subKey] }
                }
                elseif ($key -eq "RootPath" -and $loaded[$key] -and -not (@($loaded.Keys) -contains "RootPaths")) {
                    # Settings from v0.4.0 had a single root
                    $cfg.RootPaths = @($loaded[$key])
                }
                elseif ($cfg.Contains($key)) {
                    $cfg[$key] = $loaded[$key]
                }
            }
            $cfg.RootPaths = @($cfg.RootPaths | Where-Object { $_ })
        }
        catch {
            Write-Host "Settings file could not be read, using defaults: $_" -ForegroundColor Red
        }
    }

    return $cfg
}

function Save-ToolConfig {
    try {
        $toSave = [ordered]@{}
        foreach ($key in $Config.Keys) { $toSave[$key] = $Config[$key] }
        $toSave.RootPaths = @($script:SavedRootPaths)
        $toSave | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ConfigPath -Encoding utf8
    }
    catch {
        Write-Host "Could not save settings: $_" -ForegroundColor Red
    }
}

function ConvertTo-NormalPath {
    # Full path without a trailing slash (drive roots keep theirs: "D:\")
    param([string]$Path)
    $full = [System.IO.Path]::GetFullPath($Path)
    $trimmed = $full.TrimEnd("\")
    if ($trimmed.EndsWith(":")) { return "$trimmed\" }
    return $trimmed
}

function Get-RootPaths {
    return , @($Config.RootPaths | Where-Object { $_ })
}

function Get-OutputDir {
    # Archives go to the configured output folder, or to "_Archives" inside the project's root
    param([string]$Root)
    if ($Config.OutputDir) { return $Config.OutputDir }
    if (-not $Root) { $Root = (Get-RootPaths)[0] }
    return (Join-Path $Root "_Archives")
}

function Get-OutputDirText {
    if ($Config.OutputDir) { return $Config.OutputDir }
    return "<root>\_Archives (inside each projects root)"
}

function Clear-ProjectCache {
    $script:ProjectCache = $null
    $script:ProjectCacheTime = $null
}

# ============================================================
# Console helpers
# ============================================================
function Write-Title {
    param([string]$Text)
    Write-Host ""
    Write-Host "================ $Text ================" -ForegroundColor Cyan
    Write-Host ""
}

function Write-Line {
    param([string]$Text, [string]$Color = "Gray")
    $width = [Math]::Max(20, [Console]::WindowWidth - 1)
    if ($null -eq $Text) { $Text = "" }
    if ($Text.Length -gt $width) { $Text = $Text.Substring(0, $width) }
    Write-Host $Text.PadRight($width) -ForegroundColor $Color
}

function Read-KeyPress {
    return [Console]::ReadKey($true)
}

function Clear-KeyBuffer {
    while ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) }
}

function Wait-ReturnOrExit {

    Clear-KeyBuffer
    Write-Host ""
    Write-Host "Press Enter to return to menu or ESC to exit..." -ForegroundColor Gray

    while ($true) {
        $key = Read-KeyPress
        switch ($key.Key) {
            "Enter" { return }
            "Escape" { Exit-Tool }
        }
    }
}

function Read-YesNo {
    param([string]$Prompt)
    $answer = Read-Host "$Prompt (Y/N)"
    return ($answer.Trim().ToLower() -in @("y", "yes"))
}

function Format-Size {
    param([double]$Bytes)
    if ($Bytes -ge 1TB) { return "{0:N2} TB" -f ($Bytes / 1TB) }
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N1} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N0} KB" -f ($Bytes / 1KB) }
    return "{0:N0} B" -f $Bytes
}

function ConvertTo-ListText {
    param([object[]]$Values, [string]$Empty = "(none)")
    $items = @($Values | Where-Object { $_ })
    if ($items.Count -eq 0) { return $Empty }
    return ($items -join ", ")
}

function Read-ListInput {
    # Edit a comma separated list. Blank keeps the current value, "none" clears it.
    param([string]$Prompt, [object[]]$Current)
    Write-Host "Current: $(ConvertTo-ListText $Current)" -ForegroundColor DarkGray
    $text = Read-Host "$Prompt (comma separated, blank = keep, 'none' = clear)"
    if ([string]::IsNullOrWhiteSpace($text)) { return , @($Current | Where-Object { $_ }) }
    if ($text.Trim().ToLower() -eq "none") { return , @() }
    return , @($text.Split(",") | ForEach-Object { $_.Trim().Trim('"') } | Where-Object { $_ } | Select-Object -Unique)
}

# ------------------------------------------------------------
# Interactive checklist (arrow keys + space). Returns selected
# indices, or $null if cancelled with ESC.
# ------------------------------------------------------------
function Read-Checklist {

    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][object[]]$Items,   # hashtables: @{ Label = ""; Checked = $bool }
        [switch]$Single,
        [int]$Cursor = 0
    )

    $count = $Items.Count
    if ($count -eq 0) { return , @() }

    $checked = [bool[]]::new($count)
    # Indexer, not .Checked: single-select items have no Checked key, and under
    # StrictMode reading a missing key with dot syntax throws
    for ($i = 0; $i -lt $count; $i++) { $checked[$i] = [bool]$Items[$i]["Checked"] }

    $cursor = [Math]::Min([Math]::Max(0, $Cursor), $count - 1)
    $offset = 0

    $help = if ($Single) { "Up/Down: move   Enter: select   Esc: cancel" }
    else { "Up/Down: move   Space: toggle   A: all/none   Enter: confirm   Esc: cancel" }

    Clear-KeyBuffer
    Clear-Host
    [Console]::CursorVisible = $false

    try {
        while ($true) {

            $view = [Math]::Max(3, [Console]::WindowHeight - 7)
            if ($cursor -lt $offset) { $offset = $cursor }
            if ($cursor -ge $offset + $view) { $offset = $cursor - $view + 1 }

            [Console]::SetCursorPosition(0, 0)
            Write-Line $Title "Cyan"
            Write-Line $help "DarkGray"
            Write-Line ""

            for ($row = 0; $row -lt $view; $row++) {
                $i = $offset + $row
                if ($i -ge $count) { Write-Line ""; continue }

                $pointer = if ($i -eq $cursor) { "> " } else { "  " }
                $box = if ($Single) { "" } elseif ($checked[$i]) { "[x] " } else { "[ ] " }
                $color = if ($i -eq $cursor) { "Yellow" } elseif ($checked[$i] -or $Single) { "White" } else { "DarkGray" }

                Write-Line "$pointer$box$($Items[$i].Label)" $color
            }

            $status = if ($Single) { "$($cursor + 1) / $count" }
            else { "$(@($checked | Where-Object { $_ }).Count) of $count selected" }
            if ($count -gt $view) { $status += "   (scroll for more)" }

            Write-Line ""
            Write-Line $status "DarkCyan"

            $key = Read-KeyPress

            switch ($key.Key) {
                "UpArrow" { $cursor = ($cursor - 1 + $count) % $count }
                "DownArrow" { $cursor = ($cursor + 1) % $count }
                "PageUp" { $cursor = [Math]::Max(0, $cursor - $view) }
                "PageDown" { $cursor = [Math]::Min($count - 1, $cursor + $view) }
                "Home" { $cursor = 0 }
                "End" { $cursor = $count - 1 }
                "Spacebar" { if (-not $Single) { $checked[$cursor] = -not $checked[$cursor] } }
                "A" {
                    if (-not $Single) {
                        $newState = $checked -contains $false
                        for ($i = 0; $i -lt $count; $i++) { $checked[$i] = $newState }
                    }
                }
                "Enter" {
                    Clear-Host
                    if ($Single) { return , @($cursor) }
                    $selected = for ($i = 0; $i -lt $count; $i++) { if ($checked[$i]) { $i } }
                    return , @($selected)
                }
                "Escape" {
                    Clear-Host
                    return $null
                }
            }
        }
    }
    finally {
        [Console]::CursorVisible = $true
    }
}

function Select-Projects {

    param(
        [Parameter(Mandatory)][object[]]$Infos,
        [Parameter(Mandatory)][string]$Title,
        [scriptblock]$Preselect = { param($p) -not $p.IsOpen },
        [scriptblock]$Detail = { param($p) Format-Size $p.TotalBytes }
    )

    $nameWidth = [Math]::Min(40, (@($Infos | ForEach-Object { $_.Name.Length }) | Measure-Object -Maximum).Maximum)

    $showRoot = @($Infos | ForEach-Object { $_.Root } | Select-Object -Unique).Count -gt 1

    $items = foreach ($p in $Infos) {
        $open = if ($p.IsOpen) { "  [OPEN IN UNITY]" } else { "" }
        $where = if ($showRoot) { "  ($($p.Root))" } else { "" }
        @{
            Label   = "{0} {1,12}{2}{3}" -f $p.Name.PadRight($nameWidth), (& $Detail $p), $where, $open
            Checked = [bool](& $Preselect $p)
        }
    }

    $selected = Read-Checklist -Title $Title -Items @($items)
    if ($null -eq $selected) { return $null }

    return , @($selected | ForEach-Object { $Infos[$_] })
}

# ============================================================
# 7-Zip
# ============================================================
function Find-SevenZip {

    $candidates = [System.Collections.Generic.List[string]]::new()

    if ($Config.SevenZipPath) { $candidates.Add($Config.SevenZipPath) }

    $cmd = Get-Command -Name "7z.exe" -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { $candidates.Add($cmd.Source) }

    foreach ($regKey in @("HKLM:\SOFTWARE\7-Zip", "HKCU:\SOFTWARE\7-Zip", "HKLM:\SOFTWARE\WOW6432Node\7-Zip")) {
        try {
            $installPath = (Get-ItemProperty -LiteralPath $regKey -Name "Path" -ErrorAction Stop).Path
            if ($installPath) { $candidates.Add((Join-Path $installPath "7z.exe")) }
        }
        catch { }
    }

    if ($env:ProgramFiles) { $candidates.Add((Join-Path $env:ProgramFiles "7-Zip\7z.exe")) }
    if (${env:ProgramFiles(x86)}) { $candidates.Add((Join-Path ${env:ProgramFiles(x86)} "7-Zip\7z.exe")) }

    foreach ($path in $candidates) {
        if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) { return $path }
    }

    return $null
}

function Resolve-SevenZip {

    if ($script:SevenZip -and (Test-Path -LiteralPath $script:SevenZip -PathType Leaf)) { return $true }

    $script:SevenZip = Find-SevenZip

    if (-not $script:SevenZip) {
        Write-Host "7-Zip was not found." -ForegroundColor Red
        Write-Host "Install it with:  winget install 7zip.7zip" -ForegroundColor Yellow
        Write-Host "or set its path in Settings." -ForegroundColor Yellow
        return $false
    }

    return $true
}

function ConvertTo-ArgumentString {
    param([string[]]$Arguments)
    $quoted = foreach ($arg in $Arguments) {
        if ($arg -match '[\s"]') { '"' + ($arg -replace '"', '\"') + '"' } else { $arg }
    }
    return ($quoted -join " ")
}

function Invoke-SevenZip {
    # Runs 7-Zip attached to the console (so its live progress shows) and returns the exit code.
    param([string[]]$Arguments, [string]$WorkingDirectory)

    $process = Start-Process -FilePath $script:SevenZip `
        -ArgumentList (ConvertTo-ArgumentString $Arguments) `
        -WorkingDirectory $WorkingDirectory `
        -NoNewWindow -Wait -PassThru

    return $process.ExitCode
}

# ============================================================
# Project discovery and scanning
# ============================================================
function Get-UnityProjects {

    param([string[]]$Roots = (Get-RootPaths))

    $skipNames = @("ScriptBackups", "_Archives", ".uat", (Split-Path (Get-OutputDir) -Leaf))
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    $projects = foreach ($root in $Roots) {

        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }

        foreach ($dir in Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue) {

            if ($skipNames -contains $dir.Name) { continue }
            if (-not $seen.Add($dir.FullName)) { continue }   # same folder listed twice

            $hasAssets = Test-Path -LiteralPath (Join-Path $dir.FullName "Assets") -PathType Container
            $hasSettings = Test-Path -LiteralPath (Join-Path $dir.FullName "ProjectSettings") -PathType Container

            if ($hasAssets -and $hasSettings) {
                [PSCustomObject]@{ Name = $dir.Name; FullName = $dir.FullName; Root = $root }
            }
        }
    }

    return , @($projects)
}

function Test-ProjectOpen {
    # Unity holds Temp\UnityLockfile open exclusively while the project is open in the editor.
    param([string]$ProjectPath)

    $lockFile = Join-Path $ProjectPath "Temp\UnityLockfile"
    if (-not [System.IO.File]::Exists($lockFile)) { return $false }

    try {
        $stream = [System.IO.File]::Open($lockFile, "Open", "ReadWrite", "None")
        $stream.Dispose()
        return $false
    }
    catch {
        return $true
    }
}

# Self-contained: this function is also shipped into parallel runspaces,
# so it must not use anything from script scope.
function Get-ProjectInfo {

    param(
        [string]$ProjectPath,
        [string]$RootFolder,
        [string[]]$CacheFolders,
        [hashtable]$ExtensionCategory,
        [string[]]$CategoryNames,
        [int]$TopCount = 10
    )

    $recurse = [System.IO.EnumerationOptions]::new()
    $recurse.RecurseSubdirectories = $true
    $recurse.IgnoreInaccessible = $true
    $recurse.AttributesToSkip = [System.IO.FileAttributes]::ReparsePoint

    $flat = [System.IO.EnumerationOptions]::new()
    $flat.IgnoreInaccessible = $true
    $flat.AttributesToSkip = [System.IO.FileAttributes]::ReparsePoint

    $cacheSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$CacheFolders, [System.StringComparer]::OrdinalIgnoreCase)

    $categoryBytes = [ordered]@{}
    $categoryCounts = [ordered]@{}
    foreach ($name in @($CategoryNames) + "Meta") { $categoryBytes[$name] = [long]0; $categoryCounts[$name] = 0 }

    $cacheBreakdown = [ordered]@{}
    [long]$totalBytes = 0
    [long]$cacheBytes = 0
    [long]$assetsBytes = 0
    $assetFiles = 0
    $scriptCount = 0
    $lastEdited = [datetime]::MinValue
    $largest = [System.Collections.Generic.List[object]]::new()
    [long]$largestMin = 0

    $root = [System.IO.DirectoryInfo]::new($ProjectPath)

    foreach ($file in $root.EnumerateFiles("*", $flat)) { $totalBytes += $file.Length }

    foreach ($dir in $root.EnumerateDirectories("*", $flat)) {

        $isCache = $cacheSet.Contains($dir.Name)
        $isAssets = $dir.Name -eq "Assets"
        $trackEdits = -not $isCache -and $dir.Name -notin @(".git", "UserSettings", "Temp", "Library", "Logs", "obj")
        [long]$dirBytes = 0

        foreach ($file in $dir.EnumerateFiles("*", $recurse)) {

            $length = $file.Length
            $dirBytes += $length

            if ($trackEdits -and $file.LastWriteTime -gt $lastEdited) { $lastEdited = $file.LastWriteTime }

            if (-not $isAssets) { continue }

            $assetFiles++
            $ext = $file.Extension

            if ($ext -eq ".meta") { $category = "Meta" }
            else {
                $category = $ExtensionCategory[$ext]
                if (-not $category) { $category = "Other" }
                if ($ext -eq ".cs") { $scriptCount++ }
            }

            $categoryBytes[$category] += $length
            $categoryCounts[$category] += 1

            if ($largest.Count -lt $TopCount -or $length -gt $largestMin) {

                $entry = [PSCustomObject]@{ Path = $file.FullName.Substring($ProjectPath.Length).TrimStart('\'); Bytes = $length }

                if ($largest.Count -lt $TopCount) { $largest.Add($entry) }
                else {
                    $minIndex = 0
                    for ($k = 1; $k -lt $largest.Count; $k++) { if ($largest[$k].Bytes -lt $largest[$minIndex].Bytes) { $minIndex = $k } }
                    $largest[$minIndex] = $entry
                }

                if ($largest.Count -eq $TopCount) {
                    $largestMin = ($largest | Measure-Object -Property Bytes -Minimum).Minimum
                }
            }
        }

        $totalBytes += $dirBytes
        if ($isCache) { $cacheBytes += $dirBytes; $cacheBreakdown[$dir.Name] = $dirBytes }
        if ($isAssets) { $assetsBytes = $dirBytes }
    }

    # Unity version
    $unityVersion = "Unknown"
    $versionFile = Join-Path $ProjectPath "ProjectSettings\ProjectVersion.txt"
    if (Test-Path -LiteralPath $versionFile) {
        $match = Select-String -LiteralPath $versionFile -Pattern 'm_EditorVersion:\s*(\S+)' | Select-Object -First 1
        if ($match) { $unityVersion = $match.Matches[0].Groups[1].Value }
    }

    # Packages and render pipeline
    $packages = @()
    $pipeline = "Built-in"
    $manifestFile = Join-Path $ProjectPath "Packages\manifest.json"
    if (Test-Path -LiteralPath $manifestFile) {
        try {
            $manifest = Get-Content -Raw -LiteralPath $manifestFile | ConvertFrom-Json -AsHashtable
            $deps = $manifest["dependencies"]

            # packages-lock.json (Unity 2019.4+) knows where each package came from
            $lockDeps = $null
            $lockFile = Join-Path $ProjectPath "Packages\packages-lock.json"
            if (Test-Path -LiteralPath $lockFile) {
                try { $lockDeps = (Get-Content -Raw -LiteralPath $lockFile | ConvertFrom-Json -AsHashtable)["dependencies"] } catch { }
            }

            if ($deps) {
                $packages = @(foreach ($name in ($deps.Keys | Where-Object { $_ -notlike "com.unity.modules.*" } | Sort-Object)) {
                        $source = ""
                        if ($lockDeps -and $lockDeps[$name] -and $lockDeps[$name]["source"]) { $source = [string]$lockDeps[$name]["source"] }
                        [PSCustomObject]@{ Name = $name; Version = [string]$deps[$name]; Source = $source }
                    })
            }
        }
        catch { $pipeline = "Unknown" }
    }
    $packageNames = @($packages | ForEach-Object { $_.Name })
    if ($packageNames -contains "com.unity.render-pipelines.high-definition") { $pipeline = "HDRP" }
    elseif ($packageNames -contains "com.unity.render-pipelines.universal") { $pipeline = "URP" }
    elseif ($packageNames -contains "com.unity.render-pipelines.lightweight") { $pipeline = "LWRP" }

    # Open in the Unity editor?
    $isOpen = $false
    $lockFile = Join-Path $ProjectPath "Temp\UnityLockfile"
    if ([System.IO.File]::Exists($lockFile)) {
        try { $stream = [System.IO.File]::Open($lockFile, "Open", "ReadWrite", "None"); $stream.Dispose() }
        catch { $isOpen = $true }
    }

    [PSCustomObject]@{
        Name           = $root.Name
        FullName       = $ProjectPath
        Root           = $RootFolder
        UnityVersion   = $unityVersion
        Pipeline       = $pipeline
        Packages       = $packages
        IsGit          = Test-Path -LiteralPath (Join-Path $ProjectPath ".git")
        IsOpen         = $isOpen
        TotalBytes     = $totalBytes
        CacheBytes     = $cacheBytes
        CacheBreakdown = $cacheBreakdown
        AssetsBytes    = $assetsBytes
        AssetFiles     = $assetFiles
        ScriptCount    = $scriptCount
        CategoryBytes  = $categoryBytes
        CategoryCounts = $categoryCounts
        LargestFiles   = @($largest | Sort-Object Bytes -Descending)
        LastEdited     = if ($lastEdited -eq [datetime]::MinValue) { $null } else { $lastEdited }
    }
}

function Invoke-ProjectScan {

    param([object[]]$Projects)

    $total = $Projects.Count
    if ($total -eq 0) { return , @() }

    $functionText = ${function:Get-ProjectInfo}.ToString()
    $cacheFolders = @($Config.CleanupFolders)
    $extensionMap = $ExtensionCategory
    $categoryNames = $CategoryNames
    $throttle = [Math]::Max(2, [Math]::Min(8, [Environment]::ProcessorCount))

    $job = $Projects | ForEach-Object -AsJob -ThrottleLimit $throttle -Parallel {
        ${function:Get-ProjectInfo} = $using:functionText
        Get-ProjectInfo -ProjectPath $_.FullName -RootFolder $_.Root -CacheFolders $using:cacheFolders `
            -ExtensionCategory $using:extensionMap -CategoryNames $using:categoryNames
    }

    try {
        while ($job.State -in @("NotStarted", "Running")) {
            $done = @($job.ChildJobs | Where-Object { $_.State -in @("Completed", "Failed", "Stopped") }).Count
            Write-Progress -Activity "Scanning Unity projects" -Status "$done of $total done" -PercentComplete ([int](100 * $done / $total))
            Start-Sleep -Milliseconds 150
        }
        $results = @(Receive-Job -Job $job -Wait)
    }
    finally {
        Write-Progress -Activity "Scanning Unity projects" -Completed
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }

    return , @($results | Sort-Object Root, Name)
}

function Get-ProjectInfos {

    param([switch]$Refresh)

    if ($Refresh -or $null -eq $script:ProjectCache) {
        Write-Host "Scanning projects in: $((Get-RootPaths) -join ', ')" -ForegroundColor DarkCyan
        $script:ProjectCache = Invoke-ProjectScan (Get-UnityProjects)
        $script:ProjectCacheTime = Get-Date
    }

    return , $script:ProjectCache
}

# ============================================================
# Dashboard and details
# ============================================================
function Show-ProjectTable {

    param([object[]]$Infos)

    $Infos | Sort-Object TotalBytes -Descending | Format-Table -AutoSize -Property `
    @{ Name = "Project"; Expression = { $_.Name } },
    @{ Name = "Unity"; Expression = { $_.UnityVersion } },
    @{ Name = "Pipeline"; Expression = { $_.Pipeline } },
    @{ Name = "Size"; Expression = { Format-Size $_.TotalBytes }; Alignment = "Right" },
    @{ Name = "Cache"; Expression = { Format-Size $_.CacheBytes }; Alignment = "Right" },
    @{ Name = "Scripts"; Expression = { $_.ScriptCount }; Alignment = "Right" },
    @{ Name = "Last Edited"; Expression = { if ($_.LastEdited) { $_.LastEdited.ToString("yyyy-MM-dd") } else { "-" } } },
    @{ Name = "Git"; Expression = { if ($_.IsGit) { "yes" } else { "" } } },
    @{ Name = "Status"; Expression = { if ($_.IsOpen) { "OPEN" } else { "" } } } | Out-Host
}

function Write-ProjectTotals {

    param([object[]]$Infos, [string]$Label)

    $totalSize = ($Infos | Measure-Object TotalBytes -Sum).Sum
    $totalCache = ($Infos | Measure-Object CacheBytes -Sum).Sum
    $totalScripts = ($Infos | Measure-Object ScriptCount -Sum).Sum

    Write-Host "------------------- $Label -------------------" -ForegroundColor DarkCyan
    Write-Host "Total Projects : $($Infos.Count)" -ForegroundColor White
    Write-Host "Total Scripts  : $totalScripts" -ForegroundColor White
    Write-Host "Disk Usage     : $(Format-Size $totalSize)" -ForegroundColor Yellow
    Write-Host "Cleanup Gain   : $(Format-Size $totalCache)" -ForegroundColor Green
}

function Show-UnityDashboard {

    $refresh = $false

    while ($true) {

        Clear-Host
        Write-Title "UNITY PROJECT DASHBOARD"

        $infos = Get-ProjectInfos -Refresh:$refresh
        $refresh = $false

        $roots = Get-RootPaths

        if ($infos.Count -eq 0) {
            Write-Host "No Unity projects found in: $($roots -join ', ')" -ForegroundColor Red
            Write-Host "(A project needs both an Assets and a ProjectSettings folder.)" -ForegroundColor DarkGray
            Wait-ReturnOrExit
            return
        }

        # One section per root folder, each with its own totals
        foreach ($root in $roots) {

            $rootInfos = @($infos | Where-Object { $_.Root -eq $root })

            Write-Host "Root: $root" -ForegroundColor Cyan

            if ($rootInfos.Count -eq 0) {
                $reason = if (Test-Path -LiteralPath $root -PathType Container) { "no Unity projects found" } else { "folder not found" }
                Write-Host "  ($reason)" -ForegroundColor DarkYellow
                Write-Host ""
                continue
            }

            Show-ProjectTable $rootInfos
            Write-ProjectTotals -Infos $rootInfos -Label "Root totals"
            Write-Host ""
        }

        if ($roots.Count -gt 1) {
            Write-ProjectTotals -Infos $infos -Label "ALL ROOTS"
        }

        Write-Host "Scanned at     : $($script:ProjectCacheTime.ToString('HH:mm:ss'))" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "R - Rescan   D - Project details   Enter - Back   Esc - Exit" -ForegroundColor Gray

        Clear-KeyBuffer

        $next = $null
        while (-not $next) {
            $key = Read-KeyPress
            switch ($key.Key) {
                "R" { $refresh = $true; $next = "loop" }
                "D" { Show-ProjectDetailsMenu; $next = "loop" }
                "Enter" { $next = "back" }
                "Escape" { Exit-Tool }
            }
        }

        if ($next -eq "back") { return }
    }
}

function Show-ProjectDetails {

    param($Info)

    Write-Title "PROJECT DETAILS: $($Info.Name)"

    $cacheText = if ($Info.CacheBreakdown.Count -gt 0) {
        ($Info.CacheBreakdown.GetEnumerator() | ForEach-Object { "$($_.Key) $(Format-Size $_.Value)" }) -join ", "
    }
    else { "none" }

    Write-Host "Path          : $($Info.FullName)" -ForegroundColor Gray
    Write-Host "Root folder   : $($Info.Root)" -ForegroundColor Gray
    Write-Host "Unity version : $($Info.UnityVersion)" -ForegroundColor White
    Write-Host "Pipeline      : $($Info.Pipeline)" -ForegroundColor White
    Write-Host "Packages      : $($Info.Packages.Count)" -ForegroundColor White
    Write-Host "Git repo      : $(if ($Info.IsGit) { 'yes' } else { 'no' })" -ForegroundColor White
    Write-Host "Open in Unity : $(if ($Info.IsOpen) { 'YES' } else { 'no' })" -ForegroundColor $(if ($Info.IsOpen) { "Red" } else { "White" })
    Write-Host "Last edited   : $(if ($Info.LastEdited) { $Info.LastEdited.ToString('yyyy-MM-dd HH:mm') } else { '-' })" -ForegroundColor White
    Write-Host "Total size    : $(Format-Size $Info.TotalBytes)" -ForegroundColor Yellow
    Write-Host "Assets        : $(Format-Size $Info.AssetsBytes) in $($Info.AssetFiles) files" -ForegroundColor Yellow
    Write-Host "Cache         : $cacheText" -ForegroundColor Green

    Write-Host ""
    Write-Host "Assets breakdown:" -ForegroundColor Cyan

    # [long] matters: [Math]::Max(1, ...) picks the Int32 overload and fails above 2 GB
    $assetsTotal = [Math]::Max([long]1, [long]$Info.AssetsBytes)
    $rows = foreach ($name in $Info.CategoryBytes.Keys) {
        $bytes = $Info.CategoryBytes[$name]
        if ($Info.CategoryCounts[$name] -eq 0) { continue }
        $fraction = $bytes / $assetsTotal
        [PSCustomObject]@{
            Category = $name
            Files    = $Info.CategoryCounts[$name]
            Size     = Format-Size $bytes
            Share    = ("#" * [int][Math]::Round($fraction * 20)).PadRight(20, ".") + (" {0,4:P0}" -f $fraction)
            Bytes    = $bytes
        }
    }
    $rows | Sort-Object Bytes -Descending | Format-Table Category, Files, @{ Name = "Size"; Expression = { $_.Size }; Alignment = "Right" }, Share -AutoSize | Out-Host

    if ($Info.LargestFiles.Count -gt 0) {
        Write-Host "Largest files:" -ForegroundColor Cyan
        $Info.LargestFiles | Format-Table @{ Name = "Size"; Expression = { Format-Size $_.Bytes }; Alignment = "Right" }, Path -AutoSize | Out-Host
    }

    if ($Info.Packages.Count -gt 0) {
        Write-Host "Packages ($($Info.Packages.Count), excluding built-in modules):" -ForegroundColor Cyan
        $Info.Packages | Format-Table -AutoSize -Property `
        @{ Name = "Package"; Expression = { $_.Name } },
        @{ Name = "Version"; Expression = { $_.Version } },
        @{ Name = "Source"; Expression = { $_.Source } } | Out-Host
    }
}

function Show-ProjectDetailsMenu {

    $infos = Get-ProjectInfos

    if ($infos.Count -eq 0) {
        Write-Host "No Unity projects found." -ForegroundColor Red
        Wait-ReturnOrExit
        return
    }

    $showRoot = (Get-RootPaths).Count -gt 1
    $items = foreach ($p in $infos) {
        $where = if ($showRoot) { "  [$($p.Root)]" } else { "" }
        @{ Label = "$($p.Name)  ($(Format-Size $p.TotalBytes), Unity $($p.UnityVersion))$where" }
    }
    $selection = Read-Checklist -Title "Select a project to inspect" -Items @($items) -Single

    if ($null -eq $selection) { return }

    Show-ProjectDetails $infos[$selection[0]]
    Wait-ReturnOrExit
}

# ============================================================
# Cleanup
# ============================================================
function Clear-UnityProjectCache {

    Write-Title "UNITY CLEANUP"

    $infos = @((Get-ProjectInfos) | Where-Object { $_.CacheBytes -gt 0 })

    if ($infos.Count -eq 0) {
        Write-Host "No cleanup targets found (folders: $(ConvertTo-ListText $Config.CleanupFolders))." -ForegroundColor DarkYellow
        Wait-ReturnOrExit
        return
    }

    $selected = Select-Projects -Infos $infos -Title "Select projects to clean ($(ConvertTo-ListText $Config.CleanupFolders))" `
        -Detail { param($p) Format-Size $p.CacheBytes }

    if ($null -eq $selected -or $selected.Count -eq 0) {
        Write-Host "Cleanup cancelled." -ForegroundColor DarkYellow
        Wait-ReturnOrExit
        return
    }

    $targets = foreach ($p in $selected) {
        if (Test-ProjectOpen $p.FullName) { Write-Host "Skipping $($p.Name): it is open in Unity." -ForegroundColor Red }
        else { $p }
    }
    $targets = @($targets)

    if ($targets.Count -eq 0) { Wait-ReturnOrExit; return }

    $totalCleanup = ($targets | Measure-Object CacheBytes -Sum).Sum
    Write-Host ""
    Write-Host "Projects selected       : $($targets.Count)" -ForegroundColor White
    Write-Host "Total space reclaimable : $(Format-Size $totalCleanup)" -ForegroundColor Green
    Write-Host ""

    if (-not (Read-YesNo "Proceed with cleanup?")) {
        Write-Host "Cleanup cancelled." -ForegroundColor DarkYellow
        Wait-ReturnOrExit
        return
    }

    [long]$freed = 0
    [long]$processed = 0
    $failures = 0
    $activity = "Cleaning Unity projects"

    try {
        foreach ($p in $targets) {

            Write-Host ""
            Write-Host "Cleaning project: $($p.Name)" -ForegroundColor Yellow

            foreach ($entry in $p.CacheBreakdown.GetEnumerator()) {

                $path = Join-Path $p.FullName $entry.Key
                if (-not (Test-Path -LiteralPath $path)) { continue }

                $percent = [int][Math]::Min(100, 100 * $processed / [Math]::Max([long]1, [long]$totalCleanup))
                Write-Progress -Activity $activity -Status "$($p.Name)\$($entry.Key) ($(Format-Size $entry.Value))" -PercentComplete $percent

                try {
                    Remove-FolderQuietly -Path $path
                    $freed += $entry.Value
                    Write-Host "  Removed $($entry.Key) ($(Format-Size $entry.Value))" -ForegroundColor DarkYellow
                }
                catch {
                    $failures++
                    Write-Host "  FAILED to fully remove $($entry.Key): $($_.Exception.Message)" -ForegroundColor Red
                }

                $processed += $entry.Value
            }
        }
    }
    finally {
        # Always close the bar, even after Ctrl+C, so it doesn't stick to the screen
        Write-Progress -Activity $activity -Completed
    }

    Clear-ProjectCache

    Write-Host ""
    Write-Host "Cleanup completed. Freed: $(Format-Size $freed)" -ForegroundColor Green
    if ($failures -gt 0) {
        Write-Host "$failures folder(s) could not be fully removed (files in use?). Close Unity/IDEs and try again." -ForegroundColor Red
    }

    Wait-ReturnOrExit
}

# ============================================================
# Archive file selection
# ============================================================
function New-ArchiveRules {

    param(
        [object[]]$ExcludedContent = @(),
        [object[]]$ExcludePatterns = @(),
        [object[]]$IncludePatterns = @(),
        [object[]]$OnlyCategories = $null
    )

    $excludedCategories = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $excludedFolders = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($item in @($ExcludedContent | Where-Object { $_ })) {
        if ($FolderGroups.Contains($item)) { foreach ($folder in $FolderGroups[$item]) { [void]$excludedFolders.Add($folder) } }
        else { [void]$excludedCategories.Add($item) }
    }

    $only = $null
    if ($OnlyCategories) {
        $only = [System.Collections.Generic.HashSet[string]]::new([string[]]$OnlyCategories, [System.StringComparer]::OrdinalIgnoreCase)
    }

    @{
        ExcludedCategories = $excludedCategories
        ExcludedFolders    = $excludedFolders
        OnlyCategories     = $only
        ExcludePatterns    = @($ExcludePatterns | Where-Object { $_ } | ForEach-Object { $_ -replace "/", "\" })
        IncludePatterns    = @($IncludePatterns | Where-Object { $_ } | ForEach-Object { $_ -replace "/", "\" })
    }
}

function Test-PatternMatch {
    # Patterns containing a slash match the project-relative path, others match the file name.
    param([string[]]$Patterns, [string]$Name, [string]$RelativePath)
    foreach ($pattern in $Patterns) {
        if ($pattern.Contains("\")) { if ($RelativePath -like $pattern) { return $true } }
        elseif ($Name -like $pattern) { return $true }
    }
    return $false
}

function Get-ArchiveFileList {

    # Returns the files to archive for one project, relative to the project's parent folder
    # (so the archive contains "ProjectName\Assets\...").
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [Parameter(Mandatory)][string[]]$Roots,
        [Parameter(Mandatory)][hashtable]$Rules
    )

    $options = [System.IO.EnumerationOptions]::new()
    $options.RecurseSubdirectories = $true
    $options.IgnoreInaccessible = $true
    $options.AttributesToSkip = [System.IO.FileAttributes]::ReparsePoint

    $parentLength = ([System.IO.Path]::GetDirectoryName($ProjectPath)).TrimEnd("\").Length + 1
    $projectLength = $ProjectPath.TrimEnd("\").Length + 1

    $files = [System.Collections.Generic.List[string]]::new()
    [long]$bytes = 0

    $excludePatterns = [string[]]$Rules.ExcludePatterns
    $includePatterns = [string[]]$Rules.IncludePatterns
    $only = $Rules.OnlyCategories

    foreach ($rootName in $Roots) {

        $rootPath = Join-Path $ProjectPath $rootName

        if ([System.IO.File]::Exists($rootPath)) {
            $info = [System.IO.FileInfo]::new($rootPath)
            $files.Add($info.FullName.Substring($parentLength)); $bytes += $info.Length
            continue
        }
        if (-not [System.IO.Directory]::Exists($rootPath)) { continue }

        $isAssets = $rootName -eq "Assets"
        $assetsPrefixLength = $rootPath.Length + 1

        foreach ($file in [System.IO.DirectoryInfo]::new($rootPath).EnumerateFiles("*", $options)) {

            $name = $file.Name
            $relative = $file.FullName.Substring($projectLength)
            $include = $true

            # A .meta file is matched by its asset's name, so it always follows its asset
            $isMeta = $name.EndsWith(".meta", [System.StringComparison]::OrdinalIgnoreCase)
            $baseName = if ($isMeta) { $name.Substring(0, $name.Length - 5) } else { $name }
            $baseRelative = if ($isMeta) { $relative.Substring(0, $relative.Length - 5) } else { $relative }

            if ($includePatterns.Count -gt 0 -and ((Test-PatternMatch $includePatterns $name $relative) -or (Test-PatternMatch $includePatterns $baseName $baseRelative))) {
                $include = $true
            }
            elseif ($excludePatterns.Count -gt 0 -and ((Test-PatternMatch $excludePatterns $name $relative) -or (Test-PatternMatch $excludePatterns $baseName $baseRelative))) {
                $include = $false
            }
            elseif ($isAssets) {

                # Top-level folder under Assets (folder .meta files at the Assets root belong to their folder)
                $inner = $file.FullName.Substring($assetsPrefixLength)
                $separator = $inner.IndexOf("\")
                $topFolder = if ($separator -ge 0) { $inner.Substring(0, $separator) } elseif ($isMeta) { $baseName } else { "" }

                if ($topFolder -and $Rules.ExcludedFolders.Contains($topFolder)) {
                    $include = $false
                }
                else {
                    $ext = [System.IO.Path]::GetExtension($baseName)

                    if ($isMeta -and -not $ext) {
                        # Folder .meta: keep (except in "only" mode, where it would just be noise)
                        $include = ($null -eq $only)
                    }
                    else {
                        $category = $ExtensionCategory[$ext]
                        if (-not $category) { $category = "Other" }

                        if ($null -ne $only) { $include = $only.Contains($category) }
                        elseif ($Rules.ExcludedCategories.Contains($category)) { $include = $false }
                    }
                }
            }
            elseif ($null -ne $only) {
                $include = $false
            }

            if ($include) {
                $files.Add($file.FullName.Substring($parentLength))
                $bytes += $file.Length
            }
        }
    }

    [PSCustomObject]@{ Files = $files; Bytes = $bytes }
}

function Get-PresetRoots {

    param([string]$PresetKey, [System.Collections.IDictionary]$ArchiveSettings)

    $preset = $Presets[$PresetKey]
    $roots = if ($PresetKey -eq "Custom") { @($ArchiveSettings.CustomRoots) } else { @($preset.Roots) }

    if ($PresetKey -ne "ScriptsOnly") { $roots += @($ArchiveSettings.ExtraFolders) }

    $unique = [System.Collections.Generic.List[string]]::new()
    foreach ($r in $roots) {
        $clean = ([string]$r).Trim().Trim("\", "/")
        if ($clean -and -not ($unique -contains $clean)) { $unique.Add($clean) }
    }
    return , @($unique)
}

# ============================================================
# Duplicate detection
# ============================================================
function Format-Duration {
    param([double]$Seconds)
    if ($Seconds -lt 0 -or [double]::IsNaN($Seconds) -or [double]::IsInfinity($Seconds)) { return "?" }
    $t = [TimeSpan]::FromSeconds([Math]::Ceiling($Seconds))
    if ($t.TotalHours -ge 1) { return "{0} h {1:00} min" -f [int][Math]::Floor($t.TotalHours), $t.Minutes }
    if ($t.TotalMinutes -ge 1) { return "{0} min {1:00} s" -f $t.Minutes, $t.Seconds }
    return "$($t.Seconds) s"
}

# ------------------------------------------------------------
# Persistent hash cache: <root>\.uat\hashes.tsv
# Paths are relative to the root, so the cache still works when an
# external drive gets another letter. A hash is reused while the file's
# size and modified time (100 ns ticks) are unchanged.
# ------------------------------------------------------------
function Get-HashCachePath {
    param([string]$Root)
    return (Join-Path (Join-Path $Root ".uat") "hashes.tsv")
}

function Get-RootRelativePath {
    param([string]$Root, [string]$FullName)
    $prefix = $Root.TrimEnd("\") + "\"
    if (-not $FullName.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { return $null }
    return $FullName.Substring($prefix.Length)
}

function Get-HashStore {

    param([string]$Root)

    $store = $script:HashStores[$Root]
    if ($null -ne $store) { return $store }

    $store = [PSCustomObject]@{
        Root   = $Root
        ByPath = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)   # relative path -> "size|ticks|sha256"
        ByCopy = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)   # "name|size|ticks" -> sha256
        Dirty  = $false
    }

    $path = Get-HashCachePath $Root
    if ([System.IO.File]::Exists($path)) {
        try {
            foreach ($line in [System.IO.File]::ReadLines($path)) {
                if ($line.Length -eq 0 -or $line[0] -eq "#") { continue }
                $parts = $line.Split("`t")
                if ($parts.Length -ne 4) { continue }
                $store.ByPath[$parts[0]] = "$($parts[1])|$($parts[2])|$($parts[3])"
                $store.ByCopy["$([System.IO.Path]::GetFileName($parts[0]))|$($parts[1])|$($parts[2])"] = $parts[3]
            }
        }
        catch {
            Write-Host "Hash cache could not be read ($path), it will be rebuilt: $($_.Exception.Message)" -ForegroundColor DarkYellow
        }
    }

    $script:HashStores[$Root] = $store
    return $store
}

function Set-HashEntry {
    param($Store, [string]$Relative, [long]$Length, [long]$Ticks, [string]$Hash)
    $Store.ByPath[$Relative] = "$Length|$Ticks|$Hash"
    $Store.ByCopy["$([System.IO.Path]::GetFileName($Relative))|$Length|$Ticks"] = $Hash
    $Store.Dirty = $true
}

function Resolve-KnownHash {
    # Returns @{ Hash; Kind = "Cache" | "Copy" } or $null when the file has to be read.
    param($Store, [string]$Relative, [long]$Length, [long]$Ticks)

    $value = $null
    if ($Store.ByPath.TryGetValue($Relative, [ref]$value)) {
        $parts = $value.Split("|")
        if ([long]$parts[0] -eq $Length -and [long]$parts[1] -eq $Ticks) { return @{ Hash = $parts[2]; Kind = "Cache" } }
    }

    if ($Config.Dedup.TrustCopies) {
        # A copy keeps its name, size and modified time: reuse the hash of the file it was copied from
        $copyKey = "$([System.IO.Path]::GetFileName($Relative))|$Length|$Ticks"
        foreach ($s in @($Store) + @($script:HashStores.Values | Where-Object { $_ -ne $Store })) {
            $hash = $null
            if ($s.ByCopy.TryGetValue($copyKey, [ref]$hash)) {
                Set-HashEntry -Store $Store -Relative $Relative -Length $Length -Ticks $Ticks -Hash $hash
                return @{ Hash = $hash; Kind = "Copy" }
            }
        }
    }

    return $null
}

function Save-HashStores {

    foreach ($store in @($script:HashStores.Values)) {

        if (-not $store.Dirty) { continue }
        if (-not [System.IO.Directory]::Exists($store.Root)) { continue }

        $path = Get-HashCachePath $store.Root
        $tempPath = "$path.tmp"

        try {
            $dir = Split-Path $path -Parent
            if (-not [System.IO.Directory]::Exists($dir)) {
                $created = New-Item -ItemType Directory -Path $dir -Force
                $created.Attributes = $created.Attributes -bor [System.IO.FileAttributes]::Hidden
            }

            # Drop entries of project folders that no longer exist (archived and deleted)
            $folderExists = @{}
            $lines = [System.Collections.Generic.List[string]]::new()
            $lines.Add("# Unity Projects Archive Tool hash cache v1: relativePath<TAB>size<TAB>lastWriteTicksUtc<TAB>sha256")

            foreach ($kv in $store.ByPath.GetEnumerator()) {
                $top = $kv.Key.Split("\")[0]
                $exists = $folderExists[$top]
                if ($null -eq $exists) { $exists = [System.IO.Directory]::Exists((Join-Path $store.Root $top)); $folderExists[$top] = $exists }
                if (-not $exists) { continue }
                $parts = $kv.Value.Split("|")
                $lines.Add("$($kv.Key)`t$($parts[0])`t$($parts[1])`t$($parts[2])")
            }

            [System.IO.File]::WriteAllLines($tempPath, $lines, [System.Text.UTF8Encoding]::new($false))
            Move-Item -LiteralPath $tempPath -Destination $path -Force
            $store.Dirty = $false
        }
        catch {
            Write-Host "Could not save the hash cache in $($store.Root): $($_.Exception.Message)" -ForegroundColor DarkYellow
            if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue }
        }
    }
}

function Clear-HashCaches {
    $script:HashStores = @{}
    foreach ($root in (Get-RootPaths)) {
        $path = Get-HashCachePath $root
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
    }
}

# ------------------------------------------------------------
# Hashing engine: compiled once per session. Reads files in 1 MB
# sequential blocks on N threads and exposes live counters for the
# progress bar (speed + time left).
# ------------------------------------------------------------
function Initialize-Hasher {

    if ("UatHasher" -as [type]) { return }

    Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.IO;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;

public class UatHasher
{
    private long _bytesDone;
    private int _filesDone;
    private volatile string _current = "";
    private readonly CancellationTokenSource _cts = new CancellationTokenSource();

    // path -> SHA256 hex, or null when the file could not be read
    public readonly ConcurrentDictionary<string, string> Results = new ConcurrentDictionary<string, string>(StringComparer.OrdinalIgnoreCase);

    public long BytesDone { get { return Interlocked.Read(ref _bytesDone); } }
    public int FilesDone { get { return Volatile.Read(ref _filesDone); } }
    public string CurrentFile { get { return _current; } }

    public Task Start(string[] paths, int threads)
    {
        var queue = new ConcurrentQueue<string>(paths);
        var workers = new Task[Math.Max(1, threads)];
        for (int i = 0; i < workers.Length; i++)
        {
            workers[i] = Task.Factory.StartNew(() => Work(queue), TaskCreationOptions.LongRunning);
        }
        return Task.WhenAll(workers);
    }

    public void Cancel() { _cts.Cancel(); }

    private void Work(ConcurrentQueue<string> queue)
    {
        var buffer = new byte[1 << 20];
        string path;

        while (!_cts.IsCancellationRequested && queue.TryDequeue(out path))
        {
            _current = path;
            string hash = null;

            try
            {
                using (var sha = SHA256.Create())
                using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite, 1, FileOptions.SequentialScan))
                {
                    int read;
                    while ((read = stream.Read(buffer, 0, buffer.Length)) > 0)
                    {
                        if (_cts.IsCancellationRequested) { return; }
                        sha.TransformBlock(buffer, 0, read, null, 0);
                        Interlocked.Add(ref _bytesDone, read);
                    }
                    sha.TransformFinalBlock(buffer, 0, 0);
                    hash = BitConverter.ToString(sha.Hash).Replace("-", "");
                }
            }
            catch
            {
                hash = null;
            }

            Results[path] = hash;
            Interlocked.Increment(ref _filesDone);
        }
    }
}
'@
}

function Get-DriveMediaType {
    # HDD / SSD / SCM / Unspecified / Unknown for the drive holding Path (cached per drive)
    param([string]$Path)

    $driveRoot = [System.IO.Path]::GetPathRoot($Path)
    if (-not $driveRoot) { return "Unknown" }
    $cached = $script:DriveMediaTypes[$driveRoot]
    if ($cached) { return $cached }

    $type = "Unknown"
    $letter = $driveRoot.TrimEnd("\").TrimEnd(":")
    if ($letter.Length -eq 1) {
        try {
            $disk = Get-Partition -DriveLetter $letter -ErrorAction Stop | Get-Disk -ErrorAction Stop
            $physical = Get-PhysicalDisk -ErrorAction Stop | Where-Object { [string]$_.DeviceId -eq [string]$disk.Number } | Select-Object -First 1
            if ($physical -and $physical.MediaType) { $type = [string]$physical.MediaType }
        }
        catch { }
    }

    $script:DriveMediaTypes[$driveRoot] = $type
    return $type
}

function Get-HashThreads {
    # Hard drives read fastest one file at a time (parallel reads make the head seek back and forth).
    # USB and unknown drives are treated as hard drives.
    param([string]$Path)

    $configured = [int]$Config.Dedup.HashThreads
    if ($configured -gt 0) { return $configured }
    if ((Get-DriveMediaType $Path) -in @("SSD", "SCM")) { return 4 }
    return 1
}

function Invoke-FileHashing {
    # Full SHA256 of the given files (objects with FullName + Length), one batch per drive.
    # Returns a hashtable: FullName -> hash (or $null when unreadable).
    param([object[]]$Files)

    $results = @{}
    if ($Files.Count -eq 0) { return $results }

    Initialize-Hasher

    $activity = "Hashing files"
    $totalFiles = $Files.Count
    $totalBytes = [long](($Files | Measure-Object Length -Sum).Sum)
    [long]$bytesBefore = 0
    $filesBefore = 0
    $hasher = $null

    # One batch per drive; the drive type (thread count) is detected before the clock starts
    $batches = foreach ($group in ($Files | Group-Object { [System.IO.Path]::GetPathRoot($_.FullName) })) {
        Write-Progress -Activity $activity -Status "Checking drive type of $($group.Name)..."
        [PSCustomObject]@{
            Threads = Get-HashThreads -Path $group.Name
            # Path order keeps files of one folder together, which is roughly disk order
            Paths   = [string[]]@($group.Group | Sort-Object FullName | ForEach-Object { $_.FullName })
        }
    }

    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $samples = [System.Collections.Generic.Queue[object]]::new()

    try {
        foreach ($batch in $batches) {

            $threads = $batch.Threads
            $paths = $batch.Paths

            $hasher = [UatHasher]::new()
            $task = $hasher.Start($paths, $threads)
            $finished = $false

            while (-not $finished) {

                $finished = $task.Wait(250)

                $bytes = $bytesBefore + $hasher.BytesDone
                $elapsed = $clock.Elapsed.TotalSeconds
                $samples.Enqueue(@($elapsed, $bytes))
                while ($samples.Count -gt 2 -and ($elapsed - $samples.Peek()[0]) -gt 5) { [void]$samples.Dequeue() }

                # Speed over the last ~5 seconds, so it reacts to the drive but doesn't jump around
                $oldest = $samples.Peek()
                $window = $elapsed - $oldest[0]
                $rate = if ($window -ge 0.5) { ($bytes - $oldest[1]) / $window } elseif ($elapsed -gt 0) { $bytes / $elapsed } else { 0 }

                $eta = if ($rate -gt 0) { Format-Duration (($totalBytes - $bytes) / $rate) } else { "?" }
                $percent = [int][Math]::Min(100, 100 * $bytes / [Math]::Max([long]1, $totalBytes))
                $current = [System.IO.Path]::GetFileName($hasher.CurrentFile)

                Write-Progress -Activity $activity `
                    -Status ("{0:N0} of {1:N0} files - {2} of {3} - {4}/s - {5} left ({6} thread{7})" -f ($filesBefore + $hasher.FilesDone), $totalFiles,
                    (Format-Size $bytes), (Format-Size $totalBytes), (Format-Size $rate), $eta, $threads, $(if ($threads -gt 1) { "s" } else { "" })) `
                    -CurrentOperation $current -PercentComplete $percent
            }

            foreach ($kv in $hasher.Results.GetEnumerator()) { $results[$kv.Key] = $kv.Value }
            $bytesBefore += $hasher.BytesDone
            $filesBefore += $hasher.FilesDone
            $hasher = $null
        }
    }
    finally {
        if ($null -ne $hasher) { $hasher.Cancel() }   # Ctrl+C: stop the worker threads
        Write-Progress -Activity $activity -Completed
    }

    $script:LastHashStats.BytesRead += $bytesBefore
    $script:LastHashStats.Seconds += $clock.Elapsed.TotalSeconds
    return $results
}

function Get-QuickHash {
    # SHA256 of the first and last 64 KB: cheap way to tell large same-size files apart before a full hash
    param([string]$Path, [long]$Length)

    $chunk = 64KB
    $buffer = [byte[]]::new($chunk)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $stream = [System.IO.FileStream]::new($Path, "Open", "Read", "ReadWrite", 4096)

    try {
        $read = $stream.Read($buffer, 0, $chunk)
        [void]$sha.TransformBlock($buffer, 0, $read, $null, 0)

        if ($Length -gt 2 * $chunk) {
            [void]$stream.Seek(-$chunk, "End")
            $read = $stream.Read($buffer, 0, $chunk)
            [void]$sha.TransformBlock($buffer, 0, $read, $null, 0)
        }

        [void]$sha.TransformFinalBlock([byte[]]::new(0), 0, 0)
        return [BitConverter]::ToString($sha.Hash).Replace("-", "")
    }
    finally {
        $stream.Dispose()
        $sha.Dispose()
    }
}

function Get-DedupCandidates {
    # Files of the given projects that can be compared: everything except caches, VCS/IDE
    # folders and .meta files, at least MinBytes in size.
    param([object[]]$Infos, [long]$MinBytes)

    $options = [System.IO.EnumerationOptions]::new()
    $options.RecurseSubdirectories = $true
    $options.IgnoreInaccessible = $true
    $options.AttributesToSkip = [System.IO.FileAttributes]::ReparsePoint

    $skip = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @($Config.CleanupFolders) + @(".git", ".vs", ".idea", ".vscode")) { [void]$skip.Add($name) }

    $candidates = [System.Collections.Generic.List[object]]::new()

    foreach ($p in $Infos) {

        try { $dirs = @([System.IO.DirectoryInfo]::new($p.FullName).EnumerateDirectories()) }
        catch { continue }

        foreach ($dir in $dirs) {

            if ($skip.Contains($dir.Name)) { continue }
            if ($dir.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }

            foreach ($file in $dir.EnumerateFiles("*", $options)) {
                if ($file.Length -lt $MinBytes) { continue }
                if ($file.Name.EndsWith(".meta", [System.StringComparison]::OrdinalIgnoreCase)) { continue }

                $candidates.Add([PSCustomObject]@{
                        Project     = $p.Name
                        ProjectPath = $p.FullName
                        Root        = $p.Root
                        FullName    = $file.FullName
                        Length      = $file.Length
                        Ticks       = $file.LastWriteTimeUtc.Ticks
                    })
            }
        }
    }

    return , $candidates
}

function Find-DuplicateFiles {
    # Groups identical files (2+ copies). Candidates need FullName, Length, ProjectPath and Root
    # (Ticks optional). Stages:
    #   1. same size only
    #   2. saved hashes (same path, or a copy: same name + size + modified time); large unknown
    #      files are compared by a quick head/tail hash first
    #   3. full SHA256 of what is left (sequential on hard drives), saved for next time
    param([object[]]$Candidates, [long]$MinBytes = 1MB, [switch]$Rehash)

    $script:LastHashStats = [PSCustomObject]@{ Compared = 0; FromCache = 0; Copies = 0; Read = 0; Unreadable = 0; BytesRead = [long]0; Seconds = 0.0 }
    $stats = $script:LastHashStats
    $activity = "Finding duplicate assets"
    $quickMin = 16MB   # below this one sequential read is cheaper than a quick hash + a full read

    # --- Stage 1: only sizes that occur more than once can be duplicates ---
    $bySize = @{}
    foreach ($c in $Candidates) {
        if ($c.Length -lt $MinBytes) { continue }
        if ($c.FullName.EndsWith(".meta", [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        $list = $bySize[$c.Length]
        if ($null -eq $list) { $list = [System.Collections.Generic.List[object]]::new(); $bySize[$c.Length] = $list }
        $list.Add($c)
    }

    $sameSize = [System.Collections.Generic.List[object]]::new()
    foreach ($list in $bySize.Values) { if ($list.Count -ge 2) { $sameSize.AddRange($list) } }
    $stats.Compared = $sameSize.Count
    if ($sameSize.Count -eq 0) { return , @() }

    $hashes = @{}   # FullName -> SHA256
    $fileInfo = @{} # FullName -> @{ Store; Relative; Ticks }
    $unknown = [System.Collections.Generic.List[object]]::new()

    try {
        # --- Stage 2a: hashes we already know ---
        $done = 0
        foreach ($c in $sameSize) {

            $done++
            if ($done % 200 -eq 1) {
                Write-Progress -Activity $activity -Status "Checking saved hashes: $done of $($sameSize.Count)" -PercentComplete ([int](100 * $done / $sameSize.Count))
            }

            $ticks = if ($c.PSObject.Properties["Ticks"]) { [long]$c.Ticks } else {
                try { [System.IO.File]::GetLastWriteTimeUtc($c.FullName).Ticks } catch { continue }
            }

            $store = $null
            $relative = $null
            if ($c.Root) {
                $relative = Get-RootRelativePath -Root $c.Root -FullName $c.FullName
                if ($relative) { $store = Get-HashStore -Root $c.Root }
            }
            $fileInfo[$c.FullName] = @{ Store = $store; Relative = $relative; Ticks = $ticks }

            if ($store -and -not $Rehash) {
                $known = Resolve-KnownHash -Store $store -Relative $relative -Length $c.Length -Ticks $ticks
                if ($known) {
                    $hashes[$c.FullName] = $known.Hash
                    if ($known.Kind -eq "Copy") { $stats.Copies++ } else { $stats.FromCache++ }
                    continue
                }
            }
            $unknown.Add($c)
        }

        # --- Stage 2b: large unknown files - skip the ones whose head/tail is unique ---
        $toHash = [System.Collections.Generic.List[object]]::new()
        $bigBySize = @{}
        foreach ($c in $unknown) {
            if ($c.Length -lt $quickMin) { $toHash.Add($c); continue }
            $list = $bigBySize[$c.Length]
            if ($null -eq $list) { $list = [System.Collections.Generic.List[object]]::new(); $bigBySize[$c.Length] = $list }
            $list.Add($c)
        }

        foreach ($length in $bigBySize.Keys) {

            $list = $bigBySize[$length]
            $knownSameSize = @($bySize[$length] | Where-Object { $hashes.ContainsKey($_.FullName) }).Count

            if ($knownSameSize -gt 0) {
                # Can't compare a quick hash with a saved full hash: read them fully
                $toHash.AddRange($list)
                continue
            }

            $byQuick = @{}
            foreach ($c in $list) {
                Write-Progress -Activity $activity -Status "Comparing large files: $([System.IO.Path]::GetFileName($c.FullName))"
                try { $quick = Get-QuickHash -Path $c.FullName -Length $c.Length } catch { $stats.Unreadable++; continue }
                $group = $byQuick[$quick]
                if ($null -eq $group) { $group = [System.Collections.Generic.List[object]]::new(); $byQuick[$quick] = $group }
                $group.Add($c)
            }
            foreach ($group in $byQuick.Values) { if ($group.Count -ge 2) { $toHash.AddRange($group) } }
        }
    }
    finally {
        Write-Progress -Activity $activity -Completed
    }

    # --- Stage 3: full SHA256 ---
    if ($toHash.Count -gt 0) {
        $read = Invoke-FileHashing -Files @($toHash)
        foreach ($c in $toHash) {
            $hash = $read[$c.FullName]
            if (-not $hash) { $stats.Unreadable++; continue }
            $hashes[$c.FullName] = $hash
            $stats.Read++
            $info = $fileInfo[$c.FullName]
            if ($info.Store) { Set-HashEntry -Store $info.Store -Relative $info.Relative -Length $c.Length -Ticks $info.Ticks -Hash $hash }
        }
    }

    Save-HashStores

    # --- Build groups ---
    $byHash = @{}
    foreach ($c in $sameSize) {
        $full = $hashes[$c.FullName]
        if (-not $full) { continue }
        $groupKey = "$($c.Length)|$full"
        $list = $byHash[$groupKey]
        if ($null -eq $list) { $list = [System.Collections.Generic.List[object]]::new(); $byHash[$groupKey] = $list }
        $list.Add($c)
    }

    $groups = foreach ($groupKey in $byHash.Keys) {

        $files = $byHash[$groupKey]
        if ($files.Count -lt 2) { continue }

        $first = $files[0]
        $category = $ExtensionCategory[[System.IO.Path]::GetExtension($first.FullName)]
        if (-not $category) { $category = "Other" }

        [PSCustomObject]@{
            SHA256       = $groupKey.Substring($groupKey.IndexOf("|") + 1)
            Name         = [System.IO.Path]::GetFileName($first.FullName)
            Length       = [long]$first.Length
            Category     = $category
            Copies       = $files.Count
            Wasted       = [long]$first.Length * ($files.Count - 1)
            ProjectCount = @($files | ForEach-Object { $_.ProjectPath } | Select-Object -Unique).Count
            Files        = @($files)
        }
    }

    return , @($groups | Sort-Object Wasted -Descending)
}

function Get-HashStatsText {
    $s = $script:LastHashStats
    if ($null -eq $s) { return "" }
    $text = "Hashes: {0:N0} saved, {1:N0} recognised copies, {2:N0} read" -f $s.FromCache, $s.Copies, $s.Read
    if ($s.Read -gt 0) {
        $text += " ($(Format-Size $s.BytesRead) at $(Format-Size ($s.BytesRead / [Math]::Max(0.001, $s.Seconds)))/s, $(Format-Duration $s.Seconds))"
    }
    if ($s.Unreadable -gt 0) { $text += ", $($s.Unreadable) unreadable" }
    return $text
}

function Write-ArchiveManifest {

    param($Info, [System.Collections.IDictionary]$Settings, [string]$PresetKey, [string[]]$Roots, $Result, [string]$ArchivePath)

    # Files stored once in a shared pool archive instead of this archive (restore copies them back)
    $sharedPool = $null
    if ($Result.Pool -and $Result.Pooled.Count -gt 0) {
        $sharedPool = [ordered]@{
            Archive = Split-Path $Result.Pool.Archive -Leaf
            SHA256  = $Result.Pool.SHA256
            Note    = "Files listed here are not in this archive. Extract PoolPath from the pool archive to Path (both relative to the projects root)."
            Files   = @($Result.Pooled)
        }
    }

    $manifest = [ordered]@{
        Tool             = "Unity Projects Archive Tool $($ScriptVersion -join '.')"
        Created          = (Get-Date).ToString("o")
        Project          = $Info.Name
        SourcePath       = $Info.FullName
        UnityVersion     = $Info.UnityVersion
        RenderPipeline   = $Info.Pipeline
        Packages         = $Info.Packages
        Preset           = $Presets[$PresetKey].Label
        Roots            = $Roots
        ExcludedContent  = if ($PresetKey -eq "ScriptsOnly") { @() } else { @($Settings.ExcludedContent) }
        ExcludePatterns  = @($Settings.ExcludePatterns)
        IncludePatterns  = @($Settings.IncludePatterns)
        Format           = "7z (LZMA2, solid)"
        CompressionLevel = $Config.CompressionLevel
        FileCount        = $Result.FileCount
        InputBytes       = $Result.InputBytes
        ArchiveFile      = Split-Path $ArchivePath -Leaf
        ArchiveBytes     = $Result.ArchiveBytes
        CompressionRatio = [Math]::Round($Result.ArchiveBytes / [Math]::Max([long]1, [long]$Result.InputBytes), 4)
        SHA256           = $Result.SHA256
        Verified         = $Result.Verified
        PooledBytes      = $Result.PooledBytes
        SharedPool       = $sharedPool
    }

    $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "$ArchivePath.manifest.json" -Encoding utf8
}

function Write-PoolManifest {

    param($Pool, [object[]]$Results)

    $manifest = [ordered]@{
        Tool         = "Unity Projects Archive Tool $($ScriptVersion -join '.')"
        Created      = (Get-Date).ToString("o")
        Type         = "SharedAssetPool"
        Root         = $Pool.Root
        Note         = "Shared files used by the project archives in UsedBy. Keep this file together with them."
        Format       = "7z (LZMA2, solid)"
        FileCount    = $Pool.Files.Count
        InputBytes   = $Pool.InputBytes
        SavedBytes   = $Pool.SavedBytes
        ArchiveFile  = Split-Path $Pool.Archive -Leaf
        ArchiveBytes = $Pool.ArchiveBytes
        SHA256       = $Pool.SHA256
        Verified     = $Pool.Verified
        UsedBy       = @($Results | Where-Object { $_.Pool -eq $Pool -and $_.Status -ne "Failed" } | ForEach-Object { Split-Path $_.Archive -Leaf })
        Files        = @($Pool.Entries)
    }

    $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$($Pool.Archive).manifest.json" -Encoding utf8
}

function New-VerifiedArchive {
    # Compresses files (paths relative to WorkingDirectory) into a new .7z, then tests and hashes it.
    # Returns Status (OK / Warning / Failed), Verified, ArchiveBytes, SHA256.
    param([string]$WorkingDirectory, [string]$ArchivePath, [string[]]$Files)

    $state = [PSCustomObject]@{ Status = "Failed"; Verified = $false; ArchiveBytes = [long]0; SHA256 = $null }
    $listPath = Join-Path (Split-Path $ArchivePath -Parent) ".$([System.IO.Path]::GetFileNameWithoutExtension($ArchivePath)).filelist.tmp"

    try {
        [System.IO.File]::WriteAllLines($listPath, $Files, [System.Text.UTF8Encoding]::new($false))

        $exitCode = Invoke-SevenZip -WorkingDirectory $WorkingDirectory -Arguments @(
            "a", "-t7z", $ArchivePath, "@$listPath",
            "-m0=lzma2", "-mx=$($Config.CompressionLevel)", "-mmt=on", "-ms=on", "-mqs=on",
            "-scsUTF-8", "-ssw", "-bso0", "-bsp1")

        if ($exitCode -ge 2 -or -not (Test-Path -LiteralPath $ArchivePath)) {
            Write-Host "7-Zip failed (exit code $exitCode)." -ForegroundColor Red
            if (Test-Path -LiteralPath $ArchivePath) { Remove-Item -LiteralPath $ArchivePath -Force -ErrorAction SilentlyContinue }
            return $state
        }

        $state.Status = if ($exitCode -eq 1) { "Warning" } else { "OK" }
        if ($exitCode -eq 1) {
            Write-Host "7-Zip reported warnings: some files could not be read and may be missing from the archive." -ForegroundColor DarkYellow
        }

        Write-Host "Verifying archive..." -ForegroundColor DarkCyan
        $testCode = Invoke-SevenZip -WorkingDirectory $WorkingDirectory -Arguments @("t", $ArchivePath, "-bso0", "-bsp1")
        $state.Verified = ($testCode -eq 0)
        if (-not $state.Verified) { Write-Host "Archive verification FAILED (exit code $testCode)." -ForegroundColor Red }

        $state.ArchiveBytes = (Get-Item -LiteralPath $ArchivePath).Length
        Write-Host "Hashing archive..." -ForegroundColor DarkCyan
        $state.SHA256 = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash

        return $state
    }
    finally {
        if (Test-Path -LiteralPath $listPath) { Remove-Item -LiteralPath $listPath -Force -ErrorAction SilentlyContinue }
    }
}

function Get-UniqueArchivePath {
    # <dir>\<name>_<stamp>.7z, with a numeric suffix if it already exists (never overwrite or update)
    param([string]$Directory, [string]$Name)

    $stamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $baseName = "$($Name)_$stamp"
    $suffix = 1
    while (Test-Path -LiteralPath (Join-Path $Directory "$baseName.7z")) { $suffix++; $baseName = "$($Name)_$($stamp)_$suffix" }
    return (Join-Path $Directory "$baseName.7z")
}

function New-SharedPools {
    # Finds files that occur more than once across the archive jobs of each root, moves them out of
    # the jobs' file lists and returns one pool per root (stored once in _SharedAssets_*.7z).
    param([object[]]$Jobs)

    $pools = [System.Collections.Generic.List[object]]::new()
    $minBytes = [long]$Config.Dedup.MinBytes

    foreach ($rootGroup in ($Jobs | Group-Object { $_.Info.Root })) {

        $rootJobs = @($rootGroup.Group)
        if ($rootJobs.Count -lt 2) { continue }

        # Archive paths are relative to the projects' parent folder, which is the same for one root
        $workingDir = [System.IO.Path]::GetDirectoryName($rootJobs[0].Info.FullName)

        $candidates = [System.Collections.Generic.List[object]]::new()
        foreach ($job in $rootJobs) {
            foreach ($rel in $job.List.Files) {
                if ($rel.EndsWith(".meta", [System.StringComparison]::OrdinalIgnoreCase)) { continue }
                $file = [System.IO.FileInfo]::new((Join-Path $workingDir $rel))
                if (-not $file.Exists -or $file.Length -lt $minBytes) { continue }
                $candidates.Add([PSCustomObject]@{
                        Job         = $job
                        Project     = $job.Info.Name
                        ProjectPath = $job.Info.FullName
                        Root        = $job.Info.Root
                        Ticks       = $file.LastWriteTimeUtc.Ticks
                        FullName    = $file.FullName
                        Relative    = $rel
                        Length      = $file.Length
                    })
            }
        }

        Write-Host "Looking for shared files in $($rootGroup.Name)..." -ForegroundColor DarkCyan
        $groups = Find-DuplicateFiles -Candidates @($candidates) -MinBytes $minBytes
        if ($groups.Count -eq 0) { continue }

        $pool = [PSCustomObject]@{
            Project      = "[Shared pool] $($rootGroup.Name)"
            Root         = $rootGroup.Name
            WorkingDir   = $workingDir
            OutputDir    = $rootJobs[0].OutputDir
            Archive      = $null
            Files        = [System.Collections.Generic.List[string]]::new()
            Entries      = [System.Collections.Generic.List[object]]::new()
            InputBytes   = [long]0
            SavedBytes   = [long]0
            Status       = "Failed"
            Verified     = $false
            ArchiveBytes = [long]0
            SHA256       = $null
            Pool         = $null
            Pooled       = @()
            PooledBytes  = [long]0
        }

        foreach ($g in $groups) {
            $poolPath = $g.Files[0].Relative
            $pool.Files.Add($poolPath)
            $pool.Entries.Add([ordered]@{ PoolPath = $poolPath; SHA256 = $g.SHA256; Size = $g.Length })
            $pool.InputBytes += $g.Length
            $pool.SavedBytes += $g.Wasted

            foreach ($f in $g.Files) {
                $f.Job.Pooled.Add([ordered]@{ Path = $f.Relative; PoolPath = $poolPath; SHA256 = $g.SHA256; Size = $g.Length })
                $f.Job.PooledBytes += $g.Length
                $f.Job.Pool = $pool
            }
        }

        # Take the pooled files out of each project's list (their .meta files stay with the project)
        foreach ($job in $rootJobs) {
            if ($job.Pooled.Count -eq 0) { continue }
            $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($entry in $job.Pooled) { [void]$set.Add($entry.Path) }
            $job.List = [PSCustomObject]@{
                Files = [System.Collections.Generic.List[string]]@($job.FullList.Files | Where-Object { -not $set.Contains($_) })
                Bytes = $job.FullList.Bytes - $job.PooledBytes
            }
        }

        $pools.Add($pool)
    }

    return , $pools
}

function Undo-SharedPool {
    # Pool failed: its projects go back to self-contained archives
    param($Pool, [object[]]$Jobs)

    foreach ($job in $Jobs) {
        if ($job.Pool -ne $Pool) { continue }
        $job.List = $job.FullList
        $job.Pooled.Clear()
        $job.PooledBytes = [long]0
        $job.Pool = $null
    }
}

function Remove-FolderQuietly {
    # Remove-Item in PowerShell 7.4+ shows its own "Removed X of Y files" progress bar,
    # which the console host can leave stuck on screen after it finishes. Hide it here
    # (local scope only - the tool's own progress bars are unaffected).
    param([string]$Path)

    $ProgressPreference = "SilentlyContinue"
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
}

function Remove-ProjectFolder {

    param([string]$Path, [switch]$Permanent)

    if ($Permanent) {
        Remove-FolderQuietly -Path $Path
    }
    else {
        Add-Type -AssemblyName Microsoft.VisualBasic
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory(
            $Path,
            [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
            [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
    }
}

# ============================================================
# Archive projects
# ============================================================
function Edit-ArchiveContent {

    param([System.Collections.IDictionary]$Settings)

    $options = @($CategoryNames) + @($FolderGroups.Keys)
    $excluded = @($Settings.ExcludedContent)

    $items = foreach ($option in $options) {
        $label = if ($FolderGroups.Contains($option)) { "$option  (folders: $($FolderGroups[$option] -join ', '))" }
        elseif ($CategoryExtensions.Contains($option)) { "$option  ($(($CategoryExtensions[$option] | Select-Object -First 8) -join ' '))" }
        else { "$option  (anything not listed above)" }
        @{ Label = $label; Checked = -not ($excluded -contains $option) }
    }

    $selection = Read-Checklist -Title "Content to INCLUDE in the archive (unchecked = excluded, .meta files follow their asset)" -Items @($items)
    if ($null -eq $selection) { return }

    $Settings.ExcludedContent = @(for ($i = 0; $i -lt $options.Count; $i++) { if ($selection -notcontains $i) { $options[$i] } })
}

function Edit-CustomRoots {

    param([System.Collections.IDictionary]$Settings, [object[]]$Projects)

    # Offer every top-level folder found in the selected projects
    $found = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @("Assets", "Packages", "ProjectSettings", "UserSettings")) { [void]$found.Add($name) }
    foreach ($p in $Projects) {
        foreach ($dir in Get-ChildItem -LiteralPath $p.FullName -Directory -Force -ErrorAction SilentlyContinue) { [void]$found.Add($dir.Name) }
    }

    $names = @($found)
    $current = @($Settings.CustomRoots)
    $items = foreach ($n in $names) {
        $note = if ($Config.CleanupFolders -contains $n) { "  (cache - normally not archived)" } else { "" }
        @{ Label = "$n$note"; Checked = ($current -contains $n) }
    }

    $selection = Read-Checklist -Title "Project folders to include" -Items @($items)
    if ($null -eq $selection) { return }

    $Settings.CustomRoots = @($selection | ForEach-Object { $names[$_] })
}

function Select-CompressionLevel {

    $index = [Math]::Max(0, [Array]::FindIndex([object[]]$CompressionLevels, [Predicate[object]] { param($l) $l.Level -eq $Config.CompressionLevel }))
    $items = foreach ($l in $CompressionLevels) { @{ Label = "$($l.Name) (-mx=$($l.Level))" } }

    $selection = Read-Checklist -Title "Compression level (higher = smaller, slower, more RAM)" -Items @($items) -Single -Cursor $index
    if ($null -ne $selection) { $Config.CompressionLevel = $CompressionLevels[$selection[0]].Level }
}

function Get-LevelName {
    $level = $CompressionLevels | Where-Object { $_.Level -eq $Config.CompressionLevel } | Select-Object -First 1
    if ($level) { return "$($level.Name) (-mx=$($level.Level))" }
    return "-mx=$($Config.CompressionLevel)"
}

function New-ProjectArchive {

    Write-Title "ARCHIVE PROJECTS"

    if (-not (Resolve-SevenZip)) { Wait-ReturnOrExit; return }

    $infos = Get-ProjectInfos

    if ($infos.Count -eq 0) {
        Write-Host "No Unity projects found in: $((Get-RootPaths) -join ', ')" -ForegroundColor Red
        Wait-ReturnOrExit
        return
    }

    # --- 1. Projects ---
    $selected = Select-Projects -Infos $infos -Title "Select projects to archive"
    if ($null -eq $selected -or $selected.Count -eq 0) { return }

    # --- 2. Preset ---
    $settings = $Config.Archive
    $presetKeys = @($Presets.Keys)
    $presetItems = foreach ($key in $presetKeys) { @{ Label = "{0,-20} {1}" -f $Presets[$key].Label, $Presets[$key].Description } }
    $presetIndex = [Math]::Max(0, [Array]::IndexOf($presetKeys, [string]$settings.Preset))

    $presetSelection = Read-Checklist -Title "Archive preset" -Items @($presetItems) -Single -Cursor $presetIndex
    if ($null -eq $presetSelection) { return }

    $presetKey = $presetKeys[$presetSelection[0]]
    $settings.Preset = $presetKey

    if ($presetKey -eq "Custom") { Edit-CustomRoots -Settings $settings -Projects $selected }

    # --- 3. Options screen ---
    while ($true) {

        $roots = Get-PresetRoots -PresetKey $presetKey -ArchiveSettings $settings
        $isScriptsOnly = $presetKey -eq "ScriptsOnly"

        Clear-Host
        Write-Title "ARCHIVE OPTIONS"
        Write-Host "Projects         : $($selected.Count) selected ($(Format-Size (($selected | Measure-Object TotalBytes -Sum).Sum)) on disk)" -ForegroundColor White
        Write-Host "Preset           : $($Presets[$presetKey].Label)" -ForegroundColor White
        Write-Host "Folders          : $(ConvertTo-ListText $roots)" -ForegroundColor White
        if (-not $isScriptsOnly) {
            Write-Host "Excluded content : $(ConvertTo-ListText $settings.ExcludedContent)" -ForegroundColor White
        }
        Write-Host "Exclude patterns : $(ConvertTo-ListText $settings.ExcludePatterns)" -ForegroundColor White
        Write-Host "Include patterns : $(ConvertTo-ListText $settings.IncludePatterns)  (always included)" -ForegroundColor White
        Write-Host "Compression      : 7z LZMA2 solid, $(Get-LevelName)" -ForegroundColor White
        $poolText = if ($settings.SharedPool) { "On - files of $(Format-Size $Config.Dedup.MinBytes)+ found in several selected projects are stored once in _SharedAssets_*.7z" } else { "Off - every archive is self-contained" }
        Write-Host "Shared pool      : $poolText" -ForegroundColor White
        Write-Host "Output folder    : $(Get-OutputDirText)" -ForegroundColor White
        Write-Host ""
        Write-Host "Enter - Start archiving" -ForegroundColor Green
        if (-not $isScriptsOnly) { Write-Host "C     - Choose content types (textures, video, audio, scenes...)" -ForegroundColor Cyan }
        if ($presetKey -eq "Custom") { Write-Host "P     - Choose project folders" -ForegroundColor Cyan }
        if (-not $isScriptsOnly) { Write-Host "F     - Extra project folders (e.g. Art, Docs, UserSettings)" -ForegroundColor Cyan }
        Write-Host "X     - Exclude patterns (e.g. *.blend1, *.tmp, Assets/Old/*)" -ForegroundColor Cyan
        Write-Host "I     - Include patterns (override exclusions, e.g. *.psd)" -ForegroundColor Cyan
        Write-Host "L     - Compression level" -ForegroundColor Cyan
        Write-Host "S     - Shared asset pool on/off (store duplicate files once; archives then depend on the pool)" -ForegroundColor Cyan
        Write-Host "Esc   - Cancel" -ForegroundColor DarkGray

        Clear-KeyBuffer
        $key = Read-KeyPress

        switch ($key.Key) {
            "C" { if (-not $isScriptsOnly) { Edit-ArchiveContent -Settings $settings } }
            "P" { if ($presetKey -eq "Custom") { Edit-CustomRoots -Settings $settings -Projects $selected } }
            "F" { if (-not $isScriptsOnly) { Write-Host ""; $settings.ExtraFolders = Read-ListInput "Extra folders" $settings.ExtraFolders } }
            "X" { Write-Host ""; $settings.ExcludePatterns = Read-ListInput "Exclude patterns" $settings.ExcludePatterns }
            "I" { Write-Host ""; $settings.IncludePatterns = Read-ListInput "Include patterns" $settings.IncludePatterns }
            "L" { Select-CompressionLevel }
            "S" { $settings.SharedPool = -not [bool]$settings.SharedPool }
            "Escape" { Save-ToolConfig; return }
        }

        if ($key.Key -eq "Enter") { break }
    }

    Save-ToolConfig

    $roots = Get-PresetRoots -PresetKey $presetKey -ArchiveSettings $settings
    $onlyCategories = $Presets[$presetKey].Only
    $rules = New-ArchiveRules `
        -ExcludedContent $(if ($onlyCategories) { @() } else { @($settings.ExcludedContent) }) `
        -ExcludePatterns @($settings.ExcludePatterns) `
        -IncludePatterns @($settings.IncludePatterns) `
        -OnlyCategories $onlyCategories

    # --- 4. Pre-flight ---
    Clear-Host
    Write-Title "PRE-FLIGHT CHECK"

    $jobs = [System.Collections.Generic.List[object]]::new()

    foreach ($p in $selected) {

        if (Test-ProjectOpen $p.FullName) {
            Write-Host "Skipping $($p.Name): it is open in Unity. Close the editor first." -ForegroundColor Red
            continue
        }

        Write-Host "Collecting files: $($p.Name)..." -ForegroundColor DarkCyan
        $list = Get-ArchiveFileList -ProjectPath $p.FullName -Roots $roots -Rules $rules

        if ($list.Files.Count -eq 0) {
            Write-Host "  Nothing to archive in $($p.Name) with these options - skipped." -ForegroundColor DarkYellow
            continue
        }

        $jobs.Add([PSCustomObject]@{
                Info        = $p
                List        = $list            # what goes into this project's archive
                FullList    = $list            # everything selected (List minus pooled files = List)
                OutputDir   = (Get-OutputDir -Root $p.Root)
                Pool        = $null
                Pooled      = [System.Collections.Generic.List[object]]::new()
                PooledBytes = [long]0
            })
    }

    if ($jobs.Count -eq 0) {
        Write-Host "Nothing to archive." -ForegroundColor DarkYellow
        Wait-ReturnOrExit
        return
    }

    $outputDirs = @($jobs | ForEach-Object { $_.OutputDir } | Select-Object -Unique)
    foreach ($dir in $outputDirs) {
        try {
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -ErrorAction Stop | Out-Null }
        }
        catch {
            Write-Host "Cannot create output folder $dir : $($_.Exception.Message)" -ForegroundColor Red
            Wait-ReturnOrExit
            return
        }
    }

    # Shared asset pool: files found in several projects of the same root are stored once
    $pools = [System.Collections.Generic.List[object]]::new()
    if ($settings.SharedPool) {
        if ($jobs.Count -lt 2) {
            Write-Host "Shared pool is on, but it needs 2+ projects from the same root - archiving normally." -ForegroundColor DarkGray
        }
        else {
            $pools = New-SharedPools -Jobs @($jobs)
            if ($pools.Count -eq 0) { Write-Host "No shared files found - every archive will be self-contained." -ForegroundColor DarkGray }
        }
    }

    Write-Host ""
    $jobs | Format-Table -AutoSize -Property `
    @{ Name = "Project"; Expression = { $_.Info.Name } },
    @{ Name = "Files"; Expression = { $_.List.Files.Count }; Alignment = "Right" },
    @{ Name = "To compress"; Expression = { Format-Size $_.List.Bytes }; Alignment = "Right" },
    @{ Name = "In pool"; Expression = { if ($_.Pooled.Count) { "$($_.Pooled.Count) files, $(Format-Size $_.PooledBytes)" } else { "-" } }; Alignment = "Right" },
    @{ Name = "On disk"; Expression = { Format-Size $_.Info.TotalBytes }; Alignment = "Right" },
    @{ Name = "Output"; Expression = { $_.OutputDir } } | Out-Host

    foreach ($pool in $pools) {
        Write-Host "Shared pool ($($pool.Root)): $($pool.Files.Count) files, $(Format-Size $pool.InputBytes) stored once - saves $(Format-Size $pool.SavedBytes)" -ForegroundColor Green
    }
    if ($pools.Count -gt 0) {
        Write-Host "Archives that use a pool need its _SharedAssets_*.7z to be restored completely - keep them together." -ForegroundColor DarkYellow
    }

    $inputTotal = [long](($jobs | ForEach-Object { $_.List.Bytes } | Measure-Object -Sum).Sum) + [long](($pools | Measure-Object InputBytes -Sum).Sum)
    Write-Host "Total to compress: $(Format-Size $inputTotal)" -ForegroundColor Yellow

    # Free space per output drive
    $byDrive = @{}
    foreach ($job in @($jobs) + @($pools)) {
        try {
            $bytes = if ($job.PSObject.Properties["List"]) { $job.List.Bytes } else { $job.InputBytes }
            $driveRoot = [System.IO.Path]::GetPathRoot((Resolve-Path -LiteralPath $job.OutputDir).ProviderPath)
            $byDrive[$driveRoot] = [long]$byDrive[$driveRoot] + $bytes
        }
        catch { }
    }
    foreach ($driveRoot in $byDrive.Keys) {
        try {
            $drive = [System.IO.DriveInfo]::new($driveRoot)
            Write-Host "Free space on $($drive.Name): $(Format-Size $drive.AvailableFreeSpace) (up to $(Format-Size $byDrive[$driveRoot]) will be written)" -ForegroundColor Gray
            if ($drive.AvailableFreeSpace -lt $byDrive[$driveRoot]) {
                Write-Host "WARNING: free space on $($drive.Name) is less than the uncompressed size - the archives may not fit." -ForegroundColor Red
            }
        }
        catch { }
    }

    Write-Host ""
    if (-not (Read-YesNo "Start archiving?")) { return }

    # --- 5. Compress, verify, manifest ---
    $results = [System.Collections.Generic.List[object]]::new()

    # Pools first: if one fails, its projects fall back to self-contained archives
    foreach ($pool in $pools) {

        $pool.Archive = Get-UniqueArchivePath -Directory $pool.OutputDir -Name "_SharedAssets"

        Write-Host ""
        Write-Host "Compressing shared pool for $($pool.Root) ($($pool.Files.Count) files, $(Format-Size $pool.InputBytes))" -ForegroundColor Yellow

        try {
            $state = New-VerifiedArchive -WorkingDirectory $pool.WorkingDir -ArchivePath $pool.Archive -Files @($pool.Files)
            $pool.Status = $state.Status
            $pool.Verified = $state.Verified
            $pool.ArchiveBytes = $state.ArchiveBytes
            $pool.SHA256 = $state.SHA256
        }
        catch {
            Write-Host "Error creating the shared pool: $($_.Exception.Message)" -ForegroundColor Red
        }

        if ($pool.Status -eq "OK" -and $pool.Verified) {
            Write-Host "Done: $(Format-Size $pool.ArchiveBytes)" -ForegroundColor Green
        }
        else {
            Write-Host "The shared pool did not complete cleanly - its projects will be archived self-contained instead." -ForegroundColor DarkYellow
            if ($pool.Archive -and (Test-Path -LiteralPath $pool.Archive)) { Remove-Item -LiteralPath $pool.Archive -Force -ErrorAction SilentlyContinue }
            Undo-SharedPool -Pool $pool -Jobs @($jobs)
        }
    }
    $pools = @($pools | Where-Object { $_.Status -eq "OK" -and $_.Verified })

    $index = 0

    foreach ($job in $jobs) {

        $index++
        $p = $job.Info
        # Same project name in two roots + shared output folder: never overwrite or update an existing archive
        $archivePath = Get-UniqueArchivePath -Directory $job.OutputDir -Name $p.Name
        $workingDir = [System.IO.Path]::GetDirectoryName($p.FullName)

        $result = [PSCustomObject]@{
            Project      = $p.Name
            Info         = $p
            Archive      = $archivePath
            Status       = "Failed"
            Verified     = $false
            FileCount    = $job.List.Files.Count
            InputBytes   = $job.List.Bytes
            ArchiveBytes = [long]0
            SHA256       = $null
            Pool         = $job.Pool
            Pooled       = @($job.Pooled)
            PooledBytes  = $job.PooledBytes
        }
        $results.Add($result)

        $poolNote = if ($job.Pool) { " + $($job.Pooled.Count) files in the shared pool" } else { "" }
        Write-Host ""
        Write-Host "[$index/$($jobs.Count)] Compressing $($p.Name) ($($job.List.Files.Count) files, $(Format-Size $job.List.Bytes)$poolNote)" -ForegroundColor Yellow

        try {
            $state = New-VerifiedArchive -WorkingDirectory $workingDir -ArchivePath $archivePath -Files @($job.List.Files)
            $result.Status = $state.Status
            $result.Verified = $state.Verified
            $result.ArchiveBytes = $state.ArchiveBytes
            $result.SHA256 = $state.SHA256
            if ($result.Status -eq "Failed") { continue }

            Write-ArchiveManifest -Info $p -Settings $settings -PresetKey $presetKey -Roots $roots -Result $result -ArchivePath $archivePath

            Write-Host "Done: $(Format-Size $result.ArchiveBytes) ($("{0:P0}" -f ($result.ArchiveBytes / [Math]::Max([long]1, [long]$result.InputBytes))) of original)" -ForegroundColor Green
        }
        catch {
            Write-Host "Error archiving $($p.Name): $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    foreach ($pool in $pools) {
        try { Write-PoolManifest -Pool $pool -Results @($results) }
        catch { Write-Host "Could not write the pool manifest: $($_.Exception.Message)" -ForegroundColor Red }
    }

    Clear-ProjectCache

    # --- 6. Summary ---
    Write-Title "ARCHIVE SUMMARY"

    @($pools) + @($results) | Format-Table -AutoSize -Property Project,
    @{ Name = "Input"; Expression = { Format-Size $_.InputBytes }; Alignment = "Right" },
    @{ Name = "Archive"; Expression = { if ($_.ArchiveBytes) { Format-Size $_.ArchiveBytes } else { "-" } }; Alignment = "Right" },
    @{ Name = "Ratio"; Expression = { if ($_.ArchiveBytes) { "{0:P0}" -f ($_.ArchiveBytes / [Math]::Max([long]1, [long]$_.InputBytes)) } else { "-" } }; Alignment = "Right" },
    @{ Name = "In pool"; Expression = { if ($_.PooledBytes) { Format-Size $_.PooledBytes } else { "-" } }; Alignment = "Right" },
    Status,
    @{ Name = "Verified"; Expression = { if ($_.Verified) { "yes" } else { "NO" } } } | Out-Host

    if ($pools.Count -gt 0) {
        Write-Host "Saved by the shared pool: $(Format-Size (($pools | Measure-Object SavedBytes -Sum).Sum)) of input" -ForegroundColor Green
    }
    Write-Host "Archives saved to: $($outputDirs -join ', ')" -ForegroundColor Gray

    # --- 7. Optional delete of originals (verified archives only; pooled projects also need a verified pool) ---
    $deletable = @($results | Where-Object {
            $_.Verified -and $_.Status -eq "OK" -and ($null -eq $_.Pool -or ($_.Pool.Verified -and $_.Pool.Status -eq "OK"))
        })

    if ($deletable.Count -eq 0) {
        Write-Host ""
        Write-Host "No project qualifies for deletion (needs an archive that completed without warnings and verified)." -ForegroundColor DarkYellow
        Wait-ReturnOrExit
        return
    }

    Write-Host ""
    if (-not (Read-YesNo "Delete original project folders for the $($deletable.Count) verified archive(s)?")) {
        Write-Host "Projects were NOT deleted." -ForegroundColor Yellow
        Wait-ReturnOrExit
        return
    }

    $toDelete = Select-Projects -Infos @($deletable | ForEach-Object { $_.Info }) -Title "Select project folders to DELETE" -Preselect { param($p) $false }
    if ($null -eq $toDelete -or $toDelete.Count -eq 0) {
        Write-Host "Projects were NOT deleted." -ForegroundColor Yellow
        Wait-ReturnOrExit
        return
    }

    Write-Host "Projects to delete:" -ForegroundColor Red
    $toDelete | ForEach-Object { Write-Host "  $($_.FullName)" -ForegroundColor Red }
    $poolArchives = @($results | Where-Object { $_.Pool -and $toDelete -contains $_.Info } | ForEach-Object { $_.Pool.Archive } | Select-Object -Unique)
    if ($poolArchives.Count -gt 0) {
        Write-Host ""
        Write-Host "These archives depend on a shared pool - keep it with them, or they cannot be fully restored:" -ForegroundColor DarkYellow
        $poolArchives | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkYellow }
    }
    Write-Host ""
    Write-Host "R - Move to Recycle Bin (space is freed when the bin is emptied)" -ForegroundColor Yellow
    Write-Host "P - Delete permanently" -ForegroundColor Red
    Write-Host "Anything else - Cancel" -ForegroundColor DarkGray
    $mode = (Read-Host "Delete mode").Trim().ToUpper()

    if ($mode -notin @("R", "P")) {
        Write-Host "Projects were NOT deleted." -ForegroundColor Yellow
        Wait-ReturnOrExit
        return
    }

    $confirmText = Read-Host "Type DELETE to confirm"
    if ($confirmText -cne "DELETE") {
        Write-Host "Projects were NOT deleted." -ForegroundColor Yellow
        Wait-ReturnOrExit
        return
    }

    foreach ($p in $toDelete) {
        if (Test-ProjectOpen $p.FullName) {
            Write-Host "Skipping $($p.Name): it is open in Unity." -ForegroundColor Red
            continue
        }
        try {
            Write-Host "Deleting project: $($p.Name)" -ForegroundColor DarkYellow
            Remove-ProjectFolder -Path $p.FullName -Permanent:($mode -eq "P")
        }
        catch {
            Write-Host "Failed to delete $($p.Name): $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    Clear-ProjectCache
    Write-Host ""
    Write-Host "Delete step finished." -ForegroundColor Green
    Wait-ReturnOrExit
}

# ============================================================
# Duplicate assets report
# ============================================================
function Export-DuplicateReport {

    param([object[]]$Groups, [object[]]$Infos)

    $outputDir = Get-OutputDir -Root (Get-RootPaths)[0]
    if (-not (Test-Path -LiteralPath $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }

    $base = Join-Path $outputDir "DuplicateAssets_$(Get-Date -Format 'yyyy-MM-dd_HH-mm-ss')"
    $groupId = 0

    $rows = foreach ($g in $Groups) {
        $groupId++
        foreach ($f in $g.Files) {
            [PSCustomObject]@{
                Group    = $groupId
                SHA256   = $g.SHA256
                Category = $g.Category
                Bytes    = $g.Length
                Copies   = $g.Copies
                Project  = $f.Project
                Root     = $f.Root
                Path     = $f.FullName
            }
        }
    }
    @($rows) | Export-Csv -LiteralPath "$base.csv" -Encoding utf8

    $groupId = 0
    [ordered]@{
        Tool         = "Unity Projects Archive Tool $($ScriptVersion -join '.')"
        Created      = (Get-Date).ToString("o")
        MinBytes     = $Config.Dedup.MinBytes
        Projects     = @($Infos | ForEach-Object { $_.FullName })
        WastedBytes  = [long](($Groups | Measure-Object Wasted -Sum).Sum)
        Groups       = @(foreach ($g in $Groups) {
                $groupId++
                [ordered]@{
                    Group    = $groupId
                    SHA256   = $g.SHA256
                    Name     = $g.Name
                    Category = $g.Category
                    Bytes    = $g.Length
                    Copies   = $g.Copies
                    Wasted   = $g.Wasted
                    Files    = @($g.Files | ForEach-Object { $_.FullName })
                }
            })
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$base.json" -Encoding utf8

    return $base
}

function Show-DuplicateAssets {

    Write-Title "DUPLICATE ASSETS"

    $infos = Get-ProjectInfos
    if ($infos.Count -eq 0) {
        Write-Host "No Unity projects found in: $((Get-RootPaths) -join ', ')" -ForegroundColor Red
        Wait-ReturnOrExit
        return
    }

    $selected = Select-Projects -Infos $infos -Title "Select projects to compare (duplicates are searched across all of them)" -Preselect { param($p) $true }
    if ($null -eq $selected -or $selected.Count -eq 0) { return }

    $groups = $null
    $rehash = $false
    $candidateCount = 0
    $multiRoot = @($selected | ForEach-Object { $_.Root } | Select-Object -Unique).Count -gt 1

    while ($true) {

        $minBytes = [long]$Config.Dedup.MinBytes

        if ($null -eq $groups) {
            Clear-Host
            Write-Title "DUPLICATE ASSETS"
            Write-Host "Listing files of $($selected.Count) project(s) (files of $(Format-Size $minBytes) or more)..." -ForegroundColor DarkCyan
            $candidates = Get-DedupCandidates -Infos $selected -MinBytes $minBytes
            $candidateCount = $candidates.Count
            $groups = Find-DuplicateFiles -Candidates $candidates -MinBytes $minBytes -Rehash:$rehash
            $rehash = $false
        }

        Clear-Host
        Write-Title "DUPLICATE ASSETS"

        $wasted = [long](($groups | Measure-Object Wasted -Sum).Sum)
        $extraCopies = [long](($groups | ForEach-Object { $_.Copies - 1 } | Measure-Object -Sum).Sum)

        Write-Host "Projects compared : $($selected.Count)" -ForegroundColor White
        Write-Host "Files compared    : $candidateCount (of $(Format-Size $minBytes) or more, .meta files and caches ignored)" -ForegroundColor White
        Write-Host "Duplicate groups  : $($groups.Count)  ($extraCopies extra copies)" -ForegroundColor White
        Write-Host "Wasted space      : $(Format-Size $wasted)" -ForegroundColor Yellow
        Write-Host (Get-HashStatsText) -ForegroundColor DarkGray

        if ($groups.Count -gt 0) {

            Write-Host ""
            Write-Host "By content type:" -ForegroundColor Cyan
            $groups | Group-Object Category | ForEach-Object {
                [PSCustomObject]@{
                    Category = $_.Name
                    Groups   = $_.Count
                    Wasted   = [long](($_.Group | Measure-Object Wasted -Sum).Sum)
                }
            } | Sort-Object Wasted -Descending | Format-Table -AutoSize -Property Category,
            @{ Name = "Groups"; Expression = { $_.Groups }; Alignment = "Right" },
            @{ Name = "Wasted"; Expression = { Format-Size $_.Wasted }; Alignment = "Right" } | Out-Host

            # Per project: how much of its content also exists elsewhere
            Write-Host "By project (content that has an identical copy elsewhere):" -ForegroundColor Cyan
            $perProject = @{}
            foreach ($g in $groups) {
                foreach ($f in $g.Files) {
                    $row = $perProject[$f.ProjectPath]
                    if ($null -eq $row) {
                        $row = [PSCustomObject]@{ Project = $f.Project; Root = $f.Root; Files = 0; Bytes = [long]0 }
                        $perProject[$f.ProjectPath] = $row
                    }
                    $row.Files++
                    $row.Bytes += $g.Length
                }
            }
            $projectColumns = @("Project",
                @{ Name = "Files"; Expression = { $_.Files }; Alignment = "Right" },
                @{ Name = "Shared size"; Expression = { Format-Size $_.Bytes }; Alignment = "Right" })
            if ($multiRoot) { $projectColumns += "Root" }
            $perProject.Values | Sort-Object Bytes -Descending | Format-Table -AutoSize -Property $projectColumns | Out-Host

            $top = 20
            Write-Host "Largest duplicates (top $([Math]::Min($top, $groups.Count)) of $($groups.Count)):" -ForegroundColor Cyan
            $groups | Select-Object -First $top | Format-Table -AutoSize -Property `
            @{ Name = "File"; Expression = { if ($_.Name.Length -gt 40) { $_.Name.Substring(0, 37) + "..." } else { $_.Name } } },
            @{ Name = "Size"; Expression = { Format-Size $_.Length }; Alignment = "Right" },
            @{ Name = "Copies"; Expression = { $_.Copies }; Alignment = "Right" },
            @{ Name = "Wasted"; Expression = { Format-Size $_.Wasted }; Alignment = "Right" },
            @{ Name = "Projects"; Expression = {
                    if ($_.ProjectCount -eq 1) { "$($_.Files[0].Project) (same project)" }
                    else {
                        $names = @($_.Files | ForEach-Object { $_.Project } | Select-Object -Unique)
                        $text = $names -join ", "
                        if ($text.Length -gt 50) { $text = $text.Substring(0, 47) + "..." }
                        $text
                    }
                }
            } | Out-Host

            Write-Host "Tip: Archive Projects > S (Shared asset pool) stores these files once when the projects are archived together." -ForegroundColor DarkGray
        }

        Write-Host ""
        if ($groups.Count -gt 0) {
            Write-Host "D - Show every copy of one duplicate" -ForegroundColor Cyan
            Write-Host "E - Export the full report (CSV + JSON)" -ForegroundColor Cyan
        }
        Write-Host "M - Minimum file size (now $(Format-Size $minBytes))" -ForegroundColor Cyan
        Write-Host "R - Rescan (uses saved hashes, only new or changed files are read)" -ForegroundColor Cyan
        Write-Host "H - Full re-hash (read every file again and refresh the saved hashes)" -ForegroundColor Cyan
        Write-Host "Enter / Esc - Back to menu" -ForegroundColor DarkGray

        Clear-KeyBuffer
        $key = Read-KeyPress

        switch ($key.Key) {

            "D" {
                if ($groups.Count -eq 0) { break }
                $items = foreach ($g in $groups) {
                    @{ Label = "{0,-40} {1,10}  x{2}  {3}" -f $g.Name, (Format-Size $g.Length), $g.Copies, $g.Category }
                }
                $pick = Read-Checklist -Title "Pick a duplicate to inspect" -Items @($items) -Single
                if ($null -eq $pick) { break }

                $g = $groups[$pick[0]]
                Clear-Host
                Write-Title "DUPLICATE: $($g.Name)"
                Write-Host "Size   : $(Format-Size $g.Length)   Copies: $($g.Copies)   Wasted: $(Format-Size $g.Wasted)" -ForegroundColor White
                Write-Host "SHA256 : $($g.SHA256)" -ForegroundColor DarkGray
                Write-Host ""
                foreach ($f in $g.Files) { Write-Host "  $($f.FullName)" -ForegroundColor Gray }
                Write-Host ""
                Write-Host "Press any key to go back..." -ForegroundColor DarkGray
                Clear-KeyBuffer
                [void](Read-KeyPress)
            }

            "E" {
                if ($groups.Count -eq 0) { break }
                try {
                    $base = Export-DuplicateReport -Groups $groups -Infos $selected
                    Write-Host ""
                    Write-Host "Saved: $base.csv" -ForegroundColor Green
                    Write-Host "       $base.json" -ForegroundColor Green
                }
                catch { Write-Host "Export failed: $($_.Exception.Message)" -ForegroundColor Red }
                Wait-ReturnOrExit
            }

            "M" {
                Write-Host ""
                $text = (Read-Host "Minimum file size in MB (e.g. 0.5, 1, 10)").Trim()
                $mb = 0.0
                if ([double]::TryParse($text, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$mb) -and $mb -gt 0) {
                    $Config.Dedup.MinBytes = [long]($mb * 1MB)
                    Save-ToolConfig
                    $groups = $null
                }
                elseif ($text) { Write-Host "Not a valid size." -ForegroundColor Red; Start-Sleep -Seconds 2 }
            }

            "R" { $groups = $null }

            "H" { $groups = $null; $rehash = $true }

            "Enter" { return }
            "Escape" { return }
        }
    }
}

# ============================================================
# Backup scripts
# ============================================================
function Backup-UnityScripts {

    Write-Title "UNITY SCRIPT BACKUP"

    if (-not (Resolve-SevenZip)) { Wait-ReturnOrExit; return }

    $infos = @((Get-ProjectInfos) | Where-Object { $_.CategoryCounts["Scripts"] + $_.CategoryCounts["Shaders"] -gt 0 })

    if ($infos.Count -eq 0) {
        Write-Host "No projects with scripts found." -ForegroundColor DarkYellow
        Wait-ReturnOrExit
        return
    }

    $selected = Select-Projects -Infos $infos -Title "Select projects to back up scripts from" -Preselect { param($p) $true } `
        -Detail { param($p) "$($p.ScriptCount) scripts" }
    if ($null -eq $selected -or $selected.Count -eq 0) { return }

    $modeSelection = Read-Checklist -Title "Backup mode" -Single -Items @(
        @{ Label = "Separate archive for EACH project" }
        @{ Label = "Single archive containing ALL selected projects" }
    )
    if ($null -eq $modeSelection) { return }
    $combined = $modeSelection[0] -eq 1

    $rules = New-ArchiveRules -OnlyCategories @("Scripts", "Shaders")
    $stamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"

    # Group work into batches: one per project, or one per root folder in combined mode
    # (paths inside an archive are relative to the root, so roots can't share an archive)
    $groups = @($selected | Group-Object Root)
    $batches = @(
        if ($combined) {
            $n = 0
            foreach ($g in $groups) {
                $n++
                $name = if ($groups.Count -gt 1) { "UnityScripts_Backup_$($stamp)_root$n" } else { "UnityScripts_Backup_$stamp" }
                @{ Name = $name; Projects = @($g.Group); Root = $g.Name }
            }
        }
        else { foreach ($p in $selected) { @{ Name = "$($p.Name)_Scripts_$stamp"; Projects = @($p); Root = $p.Root } } }
    )

    $created = 0
    $backupDirs = [System.Collections.Generic.List[string]]::new()

    foreach ($batch in $batches) {

        $backupRoot = Join-Path (Get-OutputDir -Root $batch.Root) "ScriptBackups"
        if (-not (Test-Path -LiteralPath $backupRoot)) { New-Item -ItemType Directory -Path $backupRoot | Out-Null }
        if (-not $backupDirs.Contains($backupRoot)) { $backupDirs.Add($backupRoot) }

        $suffix = 1
        $baseName = $batch.Name
        while (Test-Path -LiteralPath (Join-Path $backupRoot "$baseName.7z")) { $suffix++; $baseName = "$($batch.Name)_$suffix" }
        $batch.Name = $baseName

        $files = [System.Collections.Generic.List[string]]::new()
        foreach ($p in $batch.Projects) {
            Write-Host "Collecting scripts: $($p.Name)" -ForegroundColor DarkCyan
            $list = Get-ArchiveFileList -ProjectPath $p.FullName -Roots @("Assets") -Rules $rules
            $files.AddRange($list.Files)
        }

        if ($files.Count -eq 0) { continue }

        $archivePath = Join-Path $backupRoot "$($batch.Name).7z"
        $listPath = Join-Path $backupRoot ".$($batch.Name).filelist.tmp"
        $workingDir = [System.IO.Path]::GetDirectoryName($batch.Projects[0].FullName)

        try {
            [System.IO.File]::WriteAllLines($listPath, $files, [System.Text.UTF8Encoding]::new($false))

            Write-Host "Writing $($batch.Name).7z ($($files.Count) files)" -ForegroundColor Yellow
            $exitCode = Invoke-SevenZip -WorkingDirectory $workingDir -Arguments @(
                "a", "-t7z", $archivePath, "@$listPath", "-m0=lzma2", "-mx=9", "-mmt=on", "-ms=on",
                "-scsUTF-8", "-ssw", "-bso0", "-bsp1")

            if ($exitCode -ge 2) { Write-Host "7-Zip failed (exit code $exitCode)." -ForegroundColor Red }
            else { $created++ }
        }
        finally {
            if (Test-Path -LiteralPath $listPath) { Remove-Item -LiteralPath $listPath -Force -ErrorAction SilentlyContinue }
        }
    }

    Write-Host ""
    Write-Host "$created backup archive(s) created in:" -ForegroundColor Green
    $backupDirs | ForEach-Object { Write-Host $_ -ForegroundColor Gray }

    Wait-ReturnOrExit
}

# ============================================================
# Settings
# ============================================================
function Select-Folder {

    param([string]$Description, [string]$Initial)

    if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne "STA") {
        Write-Host "Folder browser needs an STA console; please type the path instead." -ForegroundColor DarkYellow
        return $null
    }

    Add-Type -AssemblyName System.Windows.Forms
    $dialog = [System.Windows.Forms.FolderBrowserDialog]::new()
    $dialog.Description = $Description
    $dialog.UseDescriptionForTitle = $true
    if ($Initial -and (Test-Path -LiteralPath $Initial)) { $dialog.SelectedPath = $Initial }

    try {
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dialog.SelectedPath }
        return $null
    }
    finally { $dialog.Dispose() }
}

function Read-FolderPath {

    param([string]$Description, [string]$Current, [switch]$AllowDefault)

    Write-Host ""
    Write-Host "Current: $Current" -ForegroundColor DarkGray
    $hint = "Type a path, B to browse"
    if ($AllowDefault) { $hint += ", D for default" }
    $text = Read-Host "$hint (blank = cancel)"

    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    $text = $text.Trim().Trim('"')

    if ($text -ieq "B") { return Select-Folder -Description $Description -Initial $Current }
    if ($AllowDefault -and $text -ieq "D") { return "" }
    return $text
}

function Edit-RootFolders {

    while ($true) {

        Clear-Host
        Write-Title "PROJECT ROOT FOLDERS"

        $roots = Get-RootPaths
        for ($i = 0; $i -lt $roots.Count; $i++) {
            $root = $roots[$i]
            if (Test-Path -LiteralPath $root -PathType Container) {
                $count = (Get-UnityProjects -Roots @($root)).Count
                Write-Host ("{0}. {1}  ({2} projects)" -f ($i + 1), $root, $count) -ForegroundColor White
            }
            else {
                Write-Host ("{0}. {1}  (NOT FOUND - drive disconnected?)" -f ($i + 1), $root) -ForegroundColor DarkYellow
            }
        }

        Write-Host ""
        Write-Host "A - Add a root folder" -ForegroundColor Cyan
        if ($roots.Count -gt 1) { Write-Host "R - Remove root folders" -ForegroundColor Cyan }
        Write-Host "Enter / Esc - Back" -ForegroundColor DarkGray

        Clear-KeyBuffer
        $key = Read-KeyPress

        switch ($key.Key) {

            "A" {
                $path = Read-FolderPath -Description "Folder that contains your Unity projects" -Current $roots[0]
                if ($path) {
                    if (Test-Path -LiteralPath $path -PathType Container) {
                        $normal = ConvertTo-NormalPath (Resolve-Path -LiteralPath $path).ProviderPath
                        if ($roots -contains $normal) {
                            Write-Host "Already in the list." -ForegroundColor DarkYellow; Start-Sleep -Seconds 1
                        }
                        else {
                            $Config.RootPaths = @($roots) + $normal
                            $script:SavedRootPaths = @($Config.RootPaths)
                            Clear-ProjectCache
                            Save-ToolConfig
                        }
                    }
                    else { Write-Host "Folder not found: $path" -ForegroundColor Red; Start-Sleep -Seconds 2 }
                }
            }

            "R" {
                if ($roots.Count -gt 1) {
                    $items = foreach ($r in $roots) { @{ Label = $r; Checked = $false } }
                    $selection = Read-Checklist -Title "Select root folders to REMOVE from the list (folders on disk are not touched)" -Items @($items)
                    if ($null -ne $selection -and $selection.Count -gt 0) {
                        $remaining = @(for ($i = 0; $i -lt $roots.Count; $i++) { if ($selection -notcontains $i) { $roots[$i] } })
                        if ($remaining.Count -eq 0) {
                            Write-Host "At least one root folder must remain." -ForegroundColor Red; Start-Sleep -Seconds 2
                        }
                        else {
                            $Config.RootPaths = $remaining
                            $script:SavedRootPaths = @($Config.RootPaths)
                            Clear-ProjectCache
                            Save-ToolConfig
                        }
                    }
                }
            }

            "Enter" { return }
            "Escape" { return }
        }
    }
}

function Get-HashThreadsText {
    $threads = [int]$Config.Dedup.HashThreads
    if ($threads -gt 0) { return "$threads" }
    return "auto"
}

function Show-DedupSettings {

    while ($true) {

        Clear-Host
        Write-Title "DUPLICATE DETECTION"

        $cachedEntries = 0
        foreach ($root in (Get-RootPaths)) {
            $path = Get-HashCachePath $root
            if (Test-Path -LiteralPath $path) { $cachedEntries += [Math]::Max(0, @([System.IO.File]::ReadLines($path)).Count - 1) }
        }

        Write-Host "1 - Minimum file size : $(Format-Size $Config.Dedup.MinBytes)" -ForegroundColor Cyan
        Write-Host "2 - Trust copies      : $(if ($Config.Dedup.TrustCopies) { 'On' } else { 'Off' })" -ForegroundColor Cyan
        Write-Host "      A file with the same name, size and modified time (to 1/10,000,000 s) as an already" -ForegroundColor DarkGray
        Write-Host "      hashed file is a copy of it (Windows keeps the modified time when copying), so it isn't read." -ForegroundColor DarkGray
        Write-Host "3 - Hash threads      : $(Get-HashThreadsText)" -ForegroundColor Cyan
        foreach ($root in (Get-RootPaths)) {
            if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
            Write-Host "      $root : $(Get-DriveMediaType $root) drive -> $(Get-HashThreads -Path $root) thread(s)" -ForegroundColor DarkGray
        }
        Write-Host "4 - Clear saved hashes ($('{0:N0}' -f $cachedEntries) files in <root>\.uat\hashes.tsv)" -ForegroundColor Cyan
        Write-Host "5 - Back" -ForegroundColor DarkGray

        Clear-KeyBuffer
        $key = Read-KeyPress
        if ($key.Key -eq "Escape") { return }

        switch ($key.KeyChar) {

            "1" {
                Write-Host ""
                $text = (Read-Host "Minimum file size in MB (e.g. 0.5, 1, 10)").Trim()
                $mb = 0.0
                if ([double]::TryParse($text, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$mb) -and $mb -gt 0) {
                    $Config.Dedup.MinBytes = [long]($mb * 1MB)
                    Save-ToolConfig
                }
                elseif ($text) { Write-Host "Not a valid size." -ForegroundColor Red; Start-Sleep -Seconds 2 }
            }

            "2" { $Config.Dedup.TrustCopies = -not [bool]$Config.Dedup.TrustCopies; Save-ToolConfig }

            "3" {
                $choices = @(0, 1, 2, 4, 8)
                $items = foreach ($c in $choices) {
                    @{ Label = $(if ($c -eq 0) { "Auto (1 on hard drives and USB drives, 4 on SSDs)" } else { "$c" }) }
                }
                $current = [Math]::Max(0, [Array]::IndexOf($choices, [int]$Config.Dedup.HashThreads))
                $pick = Read-Checklist -Title "Hash threads" -Items @($items) -Single -Cursor $current
                if ($null -ne $pick) { $Config.Dedup.HashThreads = $choices[$pick[0]]; Save-ToolConfig }
            }

            "4" {
                Write-Host ""
                if (Read-YesNo "Delete the saved hashes? The next duplicate search reads every file again") {
                    Clear-HashCaches
                    Write-Host "Saved hashes deleted." -ForegroundColor Green
                    Start-Sleep -Seconds 1
                }
            }

            "5" { return }
        }
    }
}

function Show-Settings {

    while ($true) {

        Clear-Host
        Write-Title "SETTINGS"

        $sevenZipText = if ($Config.SevenZipPath) { $Config.SevenZipPath } else {
            $auto = Find-SevenZip
            if ($auto) { "auto: $auto" } else { "NOT FOUND" }
        }
        $outputText = if ($Config.OutputDir) { $Config.OutputDir } else { "$(Get-OutputDirText)  (default)" }

        Write-Host "1 - Projects root folders: $((Get-RootPaths) -join '; ')" -ForegroundColor Cyan
        Write-Host "2 - Archive output folder: $outputText" -ForegroundColor Cyan
        Write-Host "3 - 7-Zip path           : $sevenZipText" -ForegroundColor Cyan
        Write-Host "4 - Compression level    : $(Get-LevelName)" -ForegroundColor Cyan
        Write-Host "5 - Cleanup folders      : $(ConvertTo-ListText $Config.CleanupFolders)" -ForegroundColor Cyan
        Write-Host "6 - Duplicate detection  : min $(Format-Size $Config.Dedup.MinBytes), trust copies $(if ($Config.Dedup.TrustCopies) { 'on' } else { 'off' }), threads $(Get-HashThreadsText)" -ForegroundColor Cyan
        Write-Host "7 - Back" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "Settings file: $ConfigPath" -ForegroundColor DarkGray

        Clear-KeyBuffer
        $key = Read-KeyPress
        if ($key.Key -eq "Escape") { return }

        switch ($key.KeyChar) {

            "1" { Edit-RootFolders }

            "2" {
                $path = Read-FolderPath -Description "Folder where archives are written" -Current (Get-OutputDirText) -AllowDefault
                if ($null -ne $path) {
                    $Config.OutputDir = $path
                    Clear-ProjectCache
                    Save-ToolConfig
                }
            }

            "3" {
                Write-Host ""
                $path = (Read-Host "Path to 7z.exe (blank = auto-detect)").Trim().Trim('"')
                if (-not $path -or (Test-Path -LiteralPath $path -PathType Leaf)) {
                    $Config.SevenZipPath = $path
                    $script:SevenZip = $null
                    Save-ToolConfig
                }
                else { Write-Host "File not found: $path" -ForegroundColor Red; Start-Sleep -Seconds 2 }
            }

            "4" { Select-CompressionLevel; Save-ToolConfig }

            "5" {
                Write-Host ""
                Write-Host "Unity regenerates: Library, Temp, obj, Logs. Optional: UserSettings (editor layout), Build, Builds." -ForegroundColor DarkGray
                $folders = Read-ListInput "Cleanup folders" $Config.CleanupFolders
                if ($folders.Count -gt 0) {
                    $Config.CleanupFolders = $folders
                    Clear-ProjectCache
                    Save-ToolConfig
                }
            }

            "6" { Show-DedupSettings }

            "7" { return }
        }
    }
}

# ============================================================
# Startup / exit
# ============================================================
function Initialize-ScriptEnvironment {

    # Leftovers from older versions and interrupted runs
    foreach ($root in (Get-RootPaths)) {

        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }

        $leftovers = @(
            (Join-Path $root "TempBackup"),
            (Join-Path $root "_TempMergedAssets"),
            (Join-Path $root "ScriptBackups\TempBackup")
        )

        foreach ($path in $leftovers) {
            if (Test-Path -LiteralPath $path) {
                Write-Host "Removing leftover temp folder: $path" -ForegroundColor DarkYellow
                try { Remove-FolderQuietly -Path $path }
                catch { Write-Host "Failed to remove $path : $_" -ForegroundColor Red }
            }
        }

        $outputDir = Get-OutputDir -Root $root
        foreach ($dir in @($outputDir, (Join-Path $outputDir "ScriptBackups"))) {
            if (Test-Path -LiteralPath $dir) {
                Get-ChildItem -LiteralPath $dir -Filter "*.filelist.tmp" -File -Force -ErrorAction SilentlyContinue |
                Remove-Item -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Exit-Tool {

    Write-Host ""
    Write-Host "Closing Unity Projects Archive Tool..." -ForegroundColor Cyan
    Write-Host ""

    exit
}

function Show-Header {

    $sevenZip = if ($script:SevenZip) { $script:SevenZip } else { Find-SevenZip }

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor DarkCyan
    Write-Host "Unity Projects Archive Tool" -ForegroundColor Cyan
    Write-Host "Version : $($ScriptVersion -join '.')" -ForegroundColor Cyan

    $label = "Root    :"
    foreach ($root in (Get-RootPaths)) {
        if (Test-Path -LiteralPath $root -PathType Container) {
            Write-Host "$label $root  ($((Get-UnityProjects -Roots @($root)).Count) projects)" -ForegroundColor Gray
        }
        else {
            Write-Host "$label $root  (NOT FOUND)" -ForegroundColor DarkYellow
        }
        $label = "         "
    }

    Write-Host "Output  : $(Get-OutputDirText)" -ForegroundColor Gray
    if ($sevenZip) { Write-Host "7-Zip   : $sevenZip" -ForegroundColor Gray }
    else { Write-Host "7-Zip   : NOT FOUND (winget install 7zip.7zip)" -ForegroundColor Red }
    Write-Host "============================================================" -ForegroundColor DarkCyan
}

# ============================================================
# MAIN
# ============================================================
if ([Console]::IsInputRedirected) {
    Write-Host "This tool is interactive and needs a console window (input is redirected)." -ForegroundColor Red
    exit 1
}

$Config = Import-ToolConfig
$Config.RootPaths = @($Config.RootPaths | ForEach-Object { ConvertTo-NormalPath $_ } | Select-Object -Unique)
if ($Config.RootPaths.Count -eq 0) { $Config.RootPaths = @($scriptDir) }
$script:SavedRootPaths = @($Config.RootPaths)

# -RootPath overrides the saved roots for this session only
if ($RootPath) {
    $sessionRoots = foreach ($path in $RootPath) {
        if (Test-Path -LiteralPath $path -PathType Container) { ConvertTo-NormalPath (Resolve-Path -LiteralPath $path).ProviderPath }
        else { Write-Host "RootPath not found: $path" -ForegroundColor Red }
    }
    if (@($sessionRoots).Count -gt 0) { $Config.RootPaths = @($sessionRoots | Select-Object -Unique) }
}

# Missing roots (e.g. an unplugged drive) are kept and shown as NOT FOUND
if (-not @((Get-RootPaths) | Where-Object { Test-Path -LiteralPath $_ -PathType Container })) {
    Write-Host "None of the root folders exist: $((Get-RootPaths) -join ', ')" -ForegroundColor Red
    Write-Host "Add one under Settings > Projects root folders." -ForegroundColor Yellow
    Start-Sleep -Seconds 2
}

Initialize-ScriptEnvironment

while ($true) {

    Clear-Host
    Show-Header

    Write-Host ""
    Write-Host "1 - Project Dashboard" -ForegroundColor DarkCyan
    Write-Host "2 - Project Details" -ForegroundColor Cyan
    Write-Host "3 - Cleanup Projects" -ForegroundColor Yellow
    Write-Host "4 - Backup Scripts" -ForegroundColor Green
    Write-Host "5 - Archive Projects (Compress + Verify + Optional Delete)" -ForegroundColor DarkYellow
    Write-Host "6 - Duplicate Assets" -ForegroundColor Magenta
    Write-Host "7 - Settings" -ForegroundColor Gray
    Write-Host "8 - Exit" -ForegroundColor Red
    Write-Host ""
    Write-Host "Select an option (1-8) or press ESC to exit: " -ForegroundColor Gray

    Clear-KeyBuffer
    $key = Read-KeyPress

    if ($key.Key -eq "Escape") { Exit-Tool }

    Clear-Host

    switch ($key.KeyChar) {
        "1" { Show-UnityDashboard }
        "2" { Show-ProjectDetailsMenu }
        "3" { Clear-UnityProjectCache }
        "4" { Backup-UnityScripts }
        "5" { New-ProjectArchive }
        "6" { Show-DuplicateAssets }
        "7" { Show-Settings }
        "8" { Exit-Tool }
    }
}
