# UnityProjectsArchiveTool

<p align="left">
  <img src="Assets/banner.png" width="550", height="250"/>
</p>

![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B%20%7C%207-blue?logo=powershell&logoColor=white)
![Windows](https://img.shields.io/badge/platform-Windows-0078D6?logo=windows&logoColor=white)
![Unity](https://img.shields.io/badge/Unity-Project%20Tool-000000?logo=unity)
![License](https://img.shields.io/github/license/ShadowFleet33/Unity_Projects_Archive_Tool)
![Repo Size](https://img.shields.io/github/repo-size/ShadowFleet33/Unity_Projects_Archive_Tool)
![Last Commit](https://img.shields.io/github/last-commit/ShadowFleet33/Unity_Projects_Archive_Tool)

A PowerShell CLI tool for managing multiple Unity projects in a single workspace.

The tool helps maintain large collections of Unity projects by providing automated scanning, cleanup, script backups, and final asset archiving into compressed packages.

It is designed for developers who maintain many prototype projects, experiments, or archived versions and want a fast way to reduce disk usage while preserving important assets.

---

## Features

### Project Discovery

Detects Unity projects inside one or more **projects root folders**, e.g. `D:\UnityProjects` and `F:\UnityProjects`. The default is the script folder. Add or remove roots in **Settings**, or pass `-RootPath` for one session.

A folder counts as a Unity project if it contains both an `Assets` and a `ProjectSettings` folder.

---

### Project Dashboard

A fast, parallel scan grouped by root folder. Each root gets its own totals (projects, scripts, disk usage, cleanup gain), followed by a grand total. A root on a disconnected drive is shown as *folder not found*. For each project it shows:

- Unity version (from `ProjectSettings/ProjectVersion.txt`)
- render pipeline (Built-in / URP / HDRP, from `Packages/manifest.json`)
- total size and reclaimable cache size
- script count
- last edited (the newest file in the project, ignoring caches)
- whether it is a Git repo
- whether it is **currently open in Unity**

Scan results are cached for the session. Press `R` to rescan.

---

### Project Details

Pick one project to see:

- an assets breakdown by type (Textures, Models, Audio, Video, Scenes, Prefabs & Data, Scripts, Shaders...)
- its 10 largest files
- its package list, with each package's version and source (registry, git, embedded...)

---

### Duplicate Assets

Finds identical files across your projects (in all root folders), for example the same asset-store pack imported into five prototypes. It's read-only, so nothing on disk is changed.

- shows the wasted space overall, by content type and by project
- lists the largest duplicates, how many copies each has, and which projects they are in
- `D` shows every copy of one file, `E` exports the full report as CSV and JSON
- files smaller than the minimum size (default 1 MB, change it with `M` or in Settings), `.meta` files and cache folders are skipped

#### How it stays fast (even on a slow hard drive)

- **Only possible duplicates are read.** A file is only read if another file has exactly the same size. Large files (16 MB and up) are first compared by their first and last 64 KB.
- **Saved hashes.** Every SHA256 is saved in `<root>\.uat\hashes.tsv` (a hidden folder). A file is read again only when its size or modified time changes. Paths are stored relative to the root, so the cache still works if an external drive gets another letter. The second search on 70 GB of unchanged projects reads nothing.
- **Recognised copies** (Settings, on by default). A file with the same name, size and modified time (to 1/10,000,000 s) as an already-hashed file is treated as a copy of it, and isn't read. Windows keeps the modified time when you copy a file, so textures copied into a new project are recognised instantly.
- **Drive-aware reading.** Hard drives and USB drives are read one file at a time, in folder order; parallel reads make a hard drive seek back and forth. SSDs use 4 threads. You can override the thread count in Settings.
- **Progress** shows files, GB, read speed and the time left. After a search, a summary line shows how many hashes were saved, how many copies were recognised and how many files were read.

`R` rescans using the saved hashes. `H` reads every file again and refreshes them. **Settings > Duplicate detection** has the minimum size, recognised copies, hash threads, and a button to delete the saved hashes.

---

### Cleanup Tool

Removes Unity-generated folders from the projects you select:

```txt
Library
Temp
obj
Logs
```

You can change the list in **Settings**, for example to add `UserSettings` or `Builds`. Projects open in Unity are skipped, and any folder that can't be removed (files in use) is reported.

---

### Script Backup

Backs up code and shaders (`.cs`, `.asmdef`, `.shader`, `.hlsl`, `.compute`, ...) from **all of `Assets`**, keeping the folder structure. You can create one `.7z` per project or a single combined `.7z` (one per root folder).

Backups are stored in `<output folder>/ScriptBackups/`.

---

### Archive Projects

Creates **one `.7z` archive per project** using LZMA2 solid compression, which compresses much better than ZIP.

1. **Select projects** with an arrow-key / space checklist.
2. **Pick a preset:**
   - **Restorable project** (`Assets` + `Packages` + `ProjectSettings`): the project can be reopened in Unity
   - **Assets only**
   - **Scripts only**
   - **Custom**: choose any of the project's folders
3. **Tune the content:**
   - include or exclude Textures, Models, Audio, Video, Scenes, Fonts, Unity Packages (`.unitypackage`), Prefabs & Data, Scripts, Shaders, Other, `Plugins`/`ThirdParty`, `StreamingAssets` and `Samples`
   - add extra folders (e.g. `Art`, `Docs`)
   - add exclude patterns (e.g. `*.blend1`, `Assets/Old/*`)
   - add include patterns that override exclusions

   `.meta` files always follow their asset, and your choices are remembered.
4. **Pick a compression level:** Fast / Normal / Max / Ultra.
   Optionally turn on the **shared asset pool** (`S`), described below.
5. **Pre-flight check:** the tool shows file counts and sizes, checks free disk space, and refuses projects that are open in Unity.
6. Every archive is **verified** (`7z t`) and gets a `<archive>.7z.manifest.json` with the Unity version, packages, options used, sizes and SHA256.
7. **Optional delete.** Only projects whose archive completed cleanly and verified can be deleted. You confirm by typing `DELETE`, and you choose between the **Recycle Bin** and a permanent delete.

The archive layout:

```txt
_Archives/
  ProjectA_2026-01-01_12-00-00.7z
    ProjectA/Assets/...
    ProjectA/Packages/manifest.json
    ProjectA/ProjectSettings/...
  ProjectA_2026-01-01_12-00-00.7z.manifest.json
```

The source files are never touched while archiving.

#### Shared asset pool (optional)

When you archive several projects from the same root together, files that appear in more than one of them can be stored **once**, in a `_SharedAssets_<date>.7z` next to the project archives:

```txt
_Archives/
  _SharedAssets_2026-01-01_12-00-00.7z                 (one copy of each shared file)
  _SharedAssets_2026-01-01_12-00-00.7z.manifest.json   (files + which archives use them)
  ProjectA_2026-01-01_12-00-01.7z                      (everything else, incl. the shared files' .meta)
  ProjectA_2026-01-01_12-00-01.7z.manifest.json        (SharedPool: which files to take from the pool)
```

- Each project's manifest lists every pooled file (`Path`, `PoolPath`, `SHA256`), so the project can be fully restored from its archive plus the pool.
- The pool is created and verified first. If it fails, the projects are archived self-contained instead.
- A pooled project can only be deleted when both its archive and its pool verified.
- **Keep the pool with its archives:** without it, the pooled files can't be restored.

The option is off by default and is remembered.

---

### Settings

The following are stored in `UnityArchiveTool.settings.json` next to the script:

- projects root folders (add or remove; type a path or browse)
- archive output folder (default `_Archives` inside each project's root folder)
- 7-Zip path (auto-detected by default)
- compression level
- cleanup folders
- duplicate detection: minimum file size, recognised copies, hash threads
- the last-used archive options (including the shared pool)

---

## Requirements

- Windows
- **PowerShell 7+** (`winget install Microsoft.PowerShell`)
- **7-Zip** (`winget install 7zip.7zip`). It is found automatically via PATH, the registry or Program Files.

---

## Usage

Place the script next to your Unity projects, or point it at any folder:

```txt
Workspace/
  UnityProjectsArchiveTool.ps1
  ProjectA/
  ProjectB/
  ProjectC/
```

Run the script:

```powershell
pwsh .\UnityProjectsArchiveTool.ps1
pwsh .\UnityProjectsArchiveTool.ps1 -RootPath "D:\UnityProjects", "F:\UnityProjects"
```

---

## Menu

```txt
1 - Project Dashboard
2 - Project Details
3 - Cleanup Projects
4 - Backup Scripts
5 - Archive Projects (Compress + Verify + Optional Delete)
6 - Duplicate Assets
7 - Settings
8 - Exit
```

Press **ESC** at any time to exit the tool.

---

## Example Workflow

```txt
1 → View dashboard
6 → Find duplicate assets
3 → Cleanup projects
4 → Backup scripts
5 → Archive projects (and optionally delete the originals)
```

---

## Safety

- Nothing is deleted without confirmation.
- Archiving never modifies or deletes source files.
- Originals can only be deleted after their archive verified, you must type `DELETE`, and the Recycle Bin is offered.
- Projects open in the Unity editor are detected and skipped.

---

## Testing

`UnityProjectsDummyDataGenerator.ps1` creates fake Unity projects for testing. Each one includes:

- `ProjectSettings` and `Packages/manifest.json`
- scripts and `.meta` files
- incompressible "media" files and compressible YAML files
- two identical files in `Assets/Shared` in every project (to test duplicate detection and the shared pool)
- a large `Library` cache

---

## Repository Structure

```txt
UnityProjectsArchiveTool/
│
├─ UnityProjectsArchiveTool.ps1
├─ UnityProjectsDummyDataGenerator.ps1
└─ README.md
```

---

## Possible Future Improvements

|   | Status | Feature                    | Description                                                                     |
|-- | ------ | -------------------------- | ------------------------------------------------------------------------------- |
|✅| Done   | Parallel Project Scanning  | Projects are scanned in parallel in a single pass.                              |
|✅| Done   | Interactive CLI Menu       | Arrow-key checklists for projects and content types.                            |
|✅| Done   | Live Progress Bars         | Scan progress bar and live 7-Zip progress.                                      |
|✅| Done   | Archive Verification       | Each archive is tested and gets a manifest with a SHA256.                       |
|✅| Done   | Config File Support        | Root, output, cleanup folders and archive options are saved to a settings file. |
|✅| Done   | Selective Archiving        | Choose which projects and which content to archive.                             |
|✅| Done   | Asset Statistics           | Per-project breakdown by asset type and largest files.                          |
|✅| Done   | Multi-Drive Support        | Allow for selection of mutiple directories across drives                        |
|✅| Done   | Asset Deduplication        | Duplicate Assets report and an optional shared asset pool when archiving.       |
|🎯| Todo   | Restore Tool               | Restore archived projects using the manifest (including shared pool files).     |
|🎯| Todo   | Unity Hub Discovery        | Find projects from Unity Hub's project list, wherever they are.                 |
|🎯| Todo   | Logging System             | Save detailed logs for automation or CI workflows.                              |
|🎯| Todo   | CLI Parameters             | Non-interactive archive/cleanup runs for scheduled tasks.                       |
|🎯| Todo   | Duplicate Script Detection | Identify identical scripts across projects.                                     |


---
## License

MIT License

---

## Contributing

Contributions, suggestions, and improvements are welcome.
