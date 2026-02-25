# WorkspaceCleaner

**WorkspaceCleaner** is an ultra-fast, multi-threaded PowerShell utility designed to clean gigabytes of development trash, dependencies, and caching folders across your entire machine or workspace.

Instead of hunting down old project folders and manually deleting `node_modules` or running `flutter clean`, this script automatically recurses through your directories, safely skipping platform build folders, and uses highly-optimized parallel jobs to reclaim your disk space.

## Supported Frameworks & Caches
This script forcefully deletes heavy dependencies and caching folders, regardless of the language or framework:

- **Node.js** (`node_modules`)
- **React/Next.js/Vite** (`.next`, `build`, `dist`, `.vercel`)
- **Turborepo** (`.turbo`)
- **Python** (`__pycache__`, `.pytest_cache`)
- **WordPress** (`wp-content/cache`)
- **iOS / Xcode** (`DerivedData`)
- **Android / Java** (`.gradle`, `target`)
- **Dart / Flutter** (`.dart_tool`)
- **General** (`coverage`, `.cache`)

### Flutter Automation
In addition to deleting trash, the script will automatically locate every `pubspec.yaml` in your workspace and run:
1. `flutter clean`
2. `flutter pub get`
These are executed in parallel (default up to 6 projects at a time) to ensure your Dart/Flutter repositories are fresh and ready for development.

## Installation

Simply download or clone this repository, and place `WorkspaceCleaner.ps1` at the root of the folder you want to clean (e.g. `C:\Projects` or `~/Code`).

*Note: The script requires the `ThreadJob` module for multi-threading. It will automatically attempt to install it for the current user if it is missing.*

## Usage

Open your terminal or PowerShell and run:

```powershell
pwsh .\WorkspaceCleaner.ps1
```

By default, the script will:
1. Scan your current directory structure.
2. Calculate what will be deleted.
3. **Prompt you for confirmation** before permanently deleting any files.
4. Execute parallel deletion and Flutter cleanup jobs.
5. Provide a detailed summary report of reclaimed disk space and time taken.

### Advanced Parameters

You can safely run the script in CI pipelines or customize its multi-threading capabilities using parameters:

```powershell
# Run a dry run to see what *would* be deleted, without actually modifying anything
pwsh .\WorkspaceCleaner.ps1 -DryRun

# Bypass the "Are you sure?" confirmation prompt (Great for CI/CD or automation)
pwsh .\WorkspaceCleaner.ps1 -Force

# Change the target directory to clean
pwsh .\WorkspaceCleaner.ps1 -Path "D:\Archive\Old_Projects"

# Increase the number of concurrent Flutter projects being cleaned
pwsh .\WorkspaceCleaner.ps1 -MaxParallel 10

# Increase the number of concurrent Trash folders being deleted
pwsh .\WorkspaceCleaner.ps1 -MaxDeleteParallel 20
```

## Safety First
- **Smart Scanning**: It intentionally avoids recursing into folders like `ios`, `android`, `windows`, `macos`, and `.git` during the scan phase to keep discovery times under a few seconds.
- **Fail-Safe**: If a folder cannot be deleted because a file is currently locked/open in another program, the script skips it and reports it in the warnings rather than crashing to a halt.
