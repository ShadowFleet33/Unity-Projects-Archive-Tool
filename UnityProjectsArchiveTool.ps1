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
$ScriptVersion = @(0, 5, 0)
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
        }
    }
}

function Import-ToolConfig {

    $cfg = Get-DefaultConfig

    if (Test-Path -LiteralPath $ConfigPath) {
        try {
            $loaded = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json -AsHashtable

            foreach ($key in @($loaded.Keys)) {
                if ($key -eq "Archive" -and $loaded[$key] -is [System.Collections.IDictionary]) {
                    foreach ($subKey in @($loaded[$key].Keys)) { $cfg.Archive[$subKey] = $loaded[$key][$subKey] }
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

    $skipNames = @("ScriptBackups", "_Archives", (Split-Path (Get-OutputDir) -Leaf))
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

function Write-ArchiveManifest {

    param($Info, [System.Collections.IDictionary]$Settings, [string]$PresetKey, [string[]]$Roots, $Result, [string]$ArchivePath)

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
    }

    $manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath "$ArchivePath.manifest.json" -Encoding utf8
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
        Write-Host "Output folder    : $(Get-OutputDirText)" -ForegroundColor White
        Write-Host ""
        Write-Host "Enter - Start archiving" -ForegroundColor Green
        if (-not $isScriptsOnly) { Write-Host "C     - Choose content types (textures, video, audio, scenes...)" -ForegroundColor Cyan }
        if ($presetKey -eq "Custom") { Write-Host "P     - Choose project folders" -ForegroundColor Cyan }
        if (-not $isScriptsOnly) { Write-Host "F     - Extra project folders (e.g. Art, Docs, UserSettings)" -ForegroundColor Cyan }
        Write-Host "X     - Exclude patterns (e.g. *.blend1, *.tmp, Assets/Old/*)" -ForegroundColor Cyan
        Write-Host "I     - Include patterns (override exclusions, e.g. *.psd)" -ForegroundColor Cyan
        Write-Host "L     - Compression level" -ForegroundColor Cyan
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

        $jobs.Add([PSCustomObject]@{ Info = $p; List = $list; OutputDir = (Get-OutputDir -Root $p.Root) })
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

    Write-Host ""
    $jobs | Format-Table -AutoSize -Property `
    @{ Name = "Project"; Expression = { $_.Info.Name } },
    @{ Name = "Files"; Expression = { $_.List.Files.Count }; Alignment = "Right" },
    @{ Name = "To compress"; Expression = { Format-Size $_.List.Bytes }; Alignment = "Right" },
    @{ Name = "On disk"; Expression = { Format-Size $_.Info.TotalBytes }; Alignment = "Right" },
    @{ Name = "Output"; Expression = { $_.OutputDir } } | Out-Host

    $inputTotal = ($jobs | ForEach-Object { $_.List.Bytes } | Measure-Object -Sum).Sum
    Write-Host "Total to compress: $(Format-Size $inputTotal)" -ForegroundColor Yellow

    # Free space per output drive
    $byDrive = @{}
    foreach ($job in $jobs) {
        try {
            $driveRoot = [System.IO.Path]::GetPathRoot((Resolve-Path -LiteralPath $job.OutputDir).ProviderPath)
            $byDrive[$driveRoot] = [long]$byDrive[$driveRoot] + $job.List.Bytes
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
    $index = 0

    foreach ($job in $jobs) {

        $index++
        $p = $job.Info
        $outputDir = $job.OutputDir
        $stamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
        $baseName = "$($p.Name)_$stamp"
        # Same project name in two roots + shared output folder: never overwrite or update an existing archive
        $suffix = 1
        while (Test-Path -LiteralPath (Join-Path $outputDir "$baseName.7z")) { $suffix++; $baseName = "$($p.Name)_$($stamp)_$suffix" }
        $archivePath = Join-Path $outputDir "$baseName.7z"
        $listPath = Join-Path $outputDir ".$baseName.filelist.tmp"
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
        }
        $results.Add($result)

        Write-Host ""
        Write-Host "[$index/$($jobs.Count)] Compressing $($p.Name) ($($job.List.Files.Count) files, $(Format-Size $job.List.Bytes))" -ForegroundColor Yellow

        try {
            [System.IO.File]::WriteAllLines($listPath, $job.List.Files, [System.Text.UTF8Encoding]::new($false))

            $exitCode = Invoke-SevenZip -WorkingDirectory $workingDir -Arguments @(
                "a", "-t7z", $archivePath, "@$listPath",
                "-m0=lzma2", "-mx=$($Config.CompressionLevel)", "-mmt=on", "-ms=on", "-mqs=on",
                "-scsUTF-8", "-ssw", "-bso0", "-bsp1")

            if ($exitCode -ge 2 -or -not (Test-Path -LiteralPath $archivePath)) {
                Write-Host "7-Zip failed (exit code $exitCode)." -ForegroundColor Red
                if (Test-Path -LiteralPath $archivePath) { Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue }
                continue
            }

            $result.Status = if ($exitCode -eq 1) { "Warning" } else { "OK" }
            if ($exitCode -eq 1) {
                Write-Host "7-Zip reported warnings: some files could not be read and may be missing from the archive." -ForegroundColor DarkYellow
            }

            Write-Host "Verifying archive..." -ForegroundColor DarkCyan
            $testCode = Invoke-SevenZip -WorkingDirectory $workingDir -Arguments @("t", $archivePath, "-bso0", "-bsp1")
            $result.Verified = ($testCode -eq 0)

            if (-not $result.Verified) { Write-Host "Archive verification FAILED (exit code $testCode)." -ForegroundColor Red }

            $result.ArchiveBytes = (Get-Item -LiteralPath $archivePath).Length
            Write-Host "Hashing archive..." -ForegroundColor DarkCyan
            $result.SHA256 = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash

            Write-ArchiveManifest -Info $p -Settings $settings -PresetKey $presetKey -Roots $roots -Result $result -ArchivePath $archivePath

            Write-Host "Done: $(Format-Size $result.ArchiveBytes) ($("{0:P0}" -f ($result.ArchiveBytes / [Math]::Max([long]1, [long]$result.InputBytes))) of original)" -ForegroundColor Green
        }
        catch {
            Write-Host "Error archiving $($p.Name): $($_.Exception.Message)" -ForegroundColor Red
        }
        finally {
            if (Test-Path -LiteralPath $listPath) { Remove-Item -LiteralPath $listPath -Force -ErrorAction SilentlyContinue }
        }
    }

    Clear-ProjectCache

    # --- 6. Summary ---
    Write-Title "ARCHIVE SUMMARY"

    $results | Format-Table -AutoSize -Property Project,
    @{ Name = "Input"; Expression = { Format-Size $_.InputBytes }; Alignment = "Right" },
    @{ Name = "Archive"; Expression = { if ($_.ArchiveBytes) { Format-Size $_.ArchiveBytes } else { "-" } }; Alignment = "Right" },
    @{ Name = "Ratio"; Expression = { if ($_.ArchiveBytes) { "{0:P0}" -f ($_.ArchiveBytes / [Math]::Max([long]1, [long]$_.InputBytes)) } else { "-" } }; Alignment = "Right" },
    Status,
    @{ Name = "Verified"; Expression = { if ($_.Verified) { "yes" } else { "NO" } } } | Out-Host

    Write-Host "Archives saved to: $($outputDirs -join ', ')" -ForegroundColor Gray

    # --- 7. Optional delete of originals (verified archives only) ---
    $deletable = @($results | Where-Object { $_.Verified -and $_.Status -eq "OK" })

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
        Write-Host "6 - Back" -ForegroundColor DarkGray
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

            "6" { return }
        }
    }
}

# ============================================================
# Startup / exit
# ============================================================
function Initialize-ScriptEnvironment {

    # Leftovers from older versions and interrupted runs
    foreach ($root in Get-RootPaths) {

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
    foreach ($root in Get-RootPaths) {
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
if (-not @(Get-RootPaths | Where-Object { Test-Path -LiteralPath $_ -PathType Container })) {
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
    Write-Host "6 - Settings" -ForegroundColor Gray
    Write-Host "7 - Exit" -ForegroundColor Red
    Write-Host ""
    Write-Host "Select an option (1-7) or press ESC to exit: " -ForegroundColor Gray

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
        "6" { Show-Settings }
        "7" { Exit-Tool }
    }
}
