[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [Parameter(Position=0)]
    [string]$Path = $PSScriptRoot,

    [Parameter()]
    [int]$MaxParallel = 6,

    [Parameter()]
    [int]$MaxDeleteParallel = 15,

    [Parameter()]
    [switch]$Force,

    [Parameter()]
    [switch]$DryRun
)

# =====================================================
# AIO Bulk Cleaner Pro (Parallel + ETA + Smart Skip)
# =====================================================

$root = $Path
if ([string]::IsNullOrWhiteSpace($root)) {
    $root = (Get-Location).Path
}

if (-not (Test-Path -Path $root -PathType Container)) {
    Write-Error "Invalid path provided: $root"
    return
}

$root = (Resolve-Path $root).Path

# Folders we want to completely delete
$trashNames = @(
    "node_modules",    # Node.js
    ".next",           # Next.js
    ".turbo",          # Turborepo
    ".vercel",         # Vercel Cache
    "build",           # React/JS build output
    "dist",            # React/Vite/JS build output
    "coverage",        # Jest/Testing coverage
    "__pycache__",     # Python
    ".pytest_cache",   # Python
    ".dart_tool",      # Dart/Flutter
    "wp-content/cache",# WordPress
    ".cache",          # General
    "DerivedData",     # Xcode/iOS
    ".gradle",         # Android/Gradle
    "target"           # Rust/Java Maven
)

# Folders we want to skip during scanning (to save time)
$skipNames = @(
    "android",
    "ios",
    "windows",
    "linux",
    "macos",
    "web"
)

try {
    if (-not (Get-Module -Name ThreadJob -ListAvailable)) {
        Write-Host "Installing required module 'ThreadJob'..." -ForegroundColor Yellow
        Install-Module -Name ThreadJob -Scope CurrentUser -Force -ErrorAction Stop
    }
    Import-Module ThreadJob -ErrorAction Stop
} catch {
    Write-Error "Failed to install or import the 'ThreadJob' module. Please run PowerShell as Administrator or check your internet connection."
    Write-Error $_.Exception.Message
    return
}

# -------------------------
# Scan phase
# -------------------------

$scanCount = 0
$projects = [System.Collections.Generic.List[string]]::new()
$trashDirs = [System.Collections.Generic.List[string]]::new()

function Find-Projects($path) {

    $global:scanCount++

    $relative = $path.Replace($root, "").TrimStart("\")
    if ($relative -eq "") { $relative = "." }

    if ($scanCount % 10 -eq 0) {
        Write-Progress `
            -Id 1 `
            -Activity "Scanning folders" `
            -Status "$scanCount scanned | $($projects.Count) projects | $($trashDirs.Count) trash → $relative"
    }

    $name = Split-Path $path -Leaf

    if ($path -ne $root) {
        # Mark for deletion and skip recursing
        if ($trashNames -contains $name) {
            $trashDirs.Add($path)
            return
        }

        # Skip heavy build/platform folders
        if ($skipNames -contains $name) { return }

        # Skip hidden folders like .git, .idea, .vscode
        if ($name.StartsWith(".")) { return }
    }

    # check for dart/flutter project
    if (Test-Path (Join-Path $path "pubspec.yaml")) {
        $projects.Add($path)
        # We do NOT return here, so it continues scanning for nested projects or node_modules
    }

    Get-ChildItem $path -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
        Find-Projects $_.FullName
    }
}

Write-Host "🔍 Scanning starting from: $root"
$scanStart = Get-Date

Find-Projects $root
Write-Progress -Id 1 -Completed

$total = $projects.Count
$scanTime = (Get-Date) - $scanStart

Write-Host "✅ Scan done | $scanCount folders checked | $total flutter projects | $($trashDirs.Count) trash folders | $($scanTime.TotalSeconds.ToString("0.0"))s`n"

# -------------------------
# Trash Deletion Phase (Parallel)
# -------------------------

$failedDeletions = [System.Collections.Generic.List[string]]::new()

if ($trashDirs.Count -gt 0) {
    if ($DryRun) {
        Write-Host "`n[DRY RUN] Would delete $($trashDirs.Count) trash folders:" -ForegroundColor Cyan
        foreach ($trash in $trashDirs) {
            Write-Host "  - $trash" -ForegroundColor DarkGray
        }
        Write-Host ""
    } else {
        $shouldDelete = $Force.IsPresent
        
        if (-not $shouldDelete) {
            $confirmation = Read-Host "`n⚠️  WARNING: You are about to permanently delete $($trashDirs.Count) trash folders. Continue? [Y/N]"
            if ($confirmation -match "^[Yy]$") {
                $shouldDelete = $true
            } else {
                Write-Host "Operation cancelled by user." -ForegroundColor Yellow
                return
            }
        }

        if ($shouldDelete) {
            Write-Host "`n🗑️  Deleting $($trashDirs.Count) trash folders (node_modules, caches, etc) completely in parallel..."
            $deleteStart = Get-Date
            
            $activeDeleteJobs = [System.Collections.Generic.List[System.Management.Automation.Job]]::new()
            $completedCount = 0
            $queuedCount = 0
            $totalTrash = $trashDirs.Count
            $totalFreedBytes = 0

            # Function to format bytes to human readable string
            function Format-Bytes($bytes) {
                if ($bytes -ge 1GB) { return "{0:N2} GB" -f ($bytes / 1GB) }
                if ($bytes -ge 1MB) { return "{0:N2} MB" -f ($bytes / 1MB) }
                if ($bytes -ge 1KB) { return "{0:N2} KB" -f ($bytes / 1KB) }
                return "$bytes B"
            }

            foreach ($trash in $trashDirs) {
                $queuedCount++

        
        while ($activeDeleteJobs.Count -ge $maxDeleteParallel) {
            Start-Sleep -Milliseconds 100
            for ($i = $activeDeleteJobs.Count - 1; $i -ge 0; $i--) {
                $state = $activeDeleteJobs[$i].State
                if ($state -ne 'Running' -and $state -ne 'NotStarted') {
                    $result = Receive-Job $activeDeleteJobs[$i] -ErrorAction SilentlyContinue
                    Remove-Job $activeDeleteJobs[$i] -Force
                    $activeDeleteJobs.RemoveAt($i)
                    $completedCount++
                    if ($null -ne $result) {
                        $totalFreedBytes += [long]($result.Size)
                        if ($result.Failed) {
                            $failedDeletions.Add([string]($result.Path))
                        }
                    }
                }
            }
        }

        $job = Start-ThreadJob -ScriptBlock {
            param($path)
            $size = 0
            try {
                $dirObj = Get-ChildItem -Path $path -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum
                if ($dirObj.Sum -gt 0) { $size = $dirObj.Sum }
            } catch {}

            try {
                Remove-Item -Path $path -Recurse -Force -ErrorAction Stop
            } catch {
                cmd.exe /c "rmdir /s /q `"$path`"" 2>&1 | Out-Null
            }
            if (Test-Path $path) {
                return @{ Failed = $true; Path = $path; Size = $size }
            }
            return @{ Failed = $false; Size = $size }
        } -ArgumentList $trash
        
        # Add metadata for UI tracking
        $job | Add-Member -MemberType NoteProperty -Name "TrashPath" -Value $trash.Replace($root, "").TrimStart("\")
        $activeDeleteJobs.Add($job)

        $percent = if ($totalTrash -gt 0) { ($completedCount / $totalTrash) * 100 } else { 100 }
        
        $activePaths = ($activeDeleteJobs | Where-Object State -eq 'Running' | Select-Object -ExpandProperty TrashPath) -join ", "
        if ($activePaths.Length -gt 100) { $activePaths = $activePaths.Substring(0, 97) + "..." }

        Write-Progress `
            -Id 3 `
            -Activity "Deleting Trash (Parallel $maxDeleteParallel Threads) | Freed: $(Format-Bytes $totalFreedBytes)" `
            -Status "Queued: $queuedCount/$totalTrash | Completed: $completedCount/$totalTrash" `
            -CurrentOperation "Active: $activePaths" `
            -PercentComplete $percent
    }

    # Wait for remaining delete jobs
    while ($activeDeleteJobs.Count -gt 0) {
        Start-Sleep -Milliseconds 100
        for ($i = $activeDeleteJobs.Count - 1; $i -ge 0; $i--) {
            $state = $activeDeleteJobs[$i].State
            if ($state -ne 'Running' -and $state -ne 'NotStarted') {
                $result = Receive-Job $activeDeleteJobs[$i] -ErrorAction SilentlyContinue
                Remove-Job $activeDeleteJobs[$i] -Force
                $activeDeleteJobs.RemoveAt($i)
                $completedCount++
                if ($null -ne $result) {
                    $totalFreedBytes += [long]($result.Size)
                    if ($result.Failed) {
                        $failedDeletions.Add([string]($result.Path))
                    }
                }
            }
        }
        $percent = if ($totalTrash -gt 0) { ($completedCount / $totalTrash) * 100 } else { 100 }
        
        $activePaths = ($activeDeleteJobs | Where-Object State -eq 'Running' | Select-Object -ExpandProperty TrashPath) -join ", "
        if ($activePaths.Length -gt 100) { $activePaths = $activePaths.Substring(0, 97) + "..." }

        Write-Progress `
            -Id 3 `
            -Activity "Deleting Trash (Parallel $maxDeleteParallel Threads) | Freed: $(Format-Bytes $totalFreedBytes)" `
            -Status "Finishing... Completed: $completedCount/$totalTrash" `
            -CurrentOperation "Active: $activePaths" `
            -PercentComplete $percent
    }

    Write-Progress -Id 3 -Completed
    $deleteTime = (Get-Date) - $deleteStart
    Write-Host "✅ Trash deletion complete! Freed: $(Format-Bytes $totalFreedBytes) ($($deleteTime.TotalSeconds.ToString("0.0"))s)`n"
}

if ($total -eq 0) {
    if ($trashDirs.Count -eq 0) {
        Write-Host "No projects or trash found. Exiting."
    } else {
        Write-Host "🎉 Task completed successfully!"
    }
    return 
}

# -------------------------
# Clean phase (parallel)
# -------------------------

$cleanStart = Get-Date

if ($DryRun) {
    Write-Host "`n[DRY RUN] Would run 'flutter clean' and 'flutter pub get' in $($projects.Count) projects:" -ForegroundColor Cyan
    foreach ($dir in $projects) {
        Write-Host "  - $dir" -ForegroundColor DarkGray
    }
    Write-Host ""
} else {
    Write-Host "🚀 Starting Flutter Parallel Clean & Pub Get..."
$activeFlutterJobs = [System.Collections.Generic.List[System.Management.Automation.Job]]::new()
$cleanCompleted = 0
$cleanTotal = $projects.Count

foreach ($dir in $projects) {
    while ($activeFlutterJobs.Count -ge $maxParallel) {
        Start-Sleep -Milliseconds 200
        for ($i = $activeFlutterJobs.Count - 1; $i -ge 0; $i--) {
            $state = $activeFlutterJobs[$i].State
            if ($state -ne 'Running' -and $state -ne 'NotStarted') {
                Receive-Job $activeFlutterJobs[$i] 2>&1 | Out-Null
                Remove-Job $activeFlutterJobs[$i] -Force
                $activeFlutterJobs.RemoveAt($i)
                $cleanCompleted++
            }
        }
    }

    $job = Start-ThreadJob -ScriptBlock {
        param($p)
        Push-Location $p
        flutter clean | Out-Null
        flutter pub get | Out-Null
        Pop-Location
        return $p
    } -ArgumentList $dir
    
    # Add metadata for UI tracking
    $job | Add-Member -MemberType NoteProperty -Name "ProjectPath" -Value $dir.Replace($root, "").TrimStart("\")
    $activeFlutterJobs.Add($job)

    $elapsed = (Get-Date) - $cleanStart
    $avg = if ($cleanCompleted -gt 0) { $elapsed.TotalSeconds / $cleanCompleted } else { 0 }
    $eta = [TimeSpan]::FromSeconds(($cleanTotal - $cleanCompleted) * $avg)
    $percent = if ($cleanTotal -gt 0) { ($cleanCompleted / $cleanTotal) * 100 } else { 100 }

    $activeFlutterPaths = ($activeFlutterJobs | Where-Object State -eq 'Running' | Select-Object -ExpandProperty ProjectPath) -join ", "
    if ($activeFlutterPaths.Length -gt 100) { $activeFlutterPaths = $activeFlutterPaths.Substring(0, 97) + "..." }

    Write-Progress `
        -Id 2 `
        -Activity "Cleaning Flutter projects (Parallel $maxParallel Threads)" `
        -Status "$cleanCompleted/$cleanTotal | Elapsed $($elapsed.ToString('mm\:ss')) | ETA $($eta.ToString('mm\:ss'))" `
        -CurrentOperation "Active: $activeFlutterPaths" `
        -PercentComplete $percent
}

# Wait for remaining flutter jobs
while ($activeFlutterJobs.Count -gt 0) {
    Start-Sleep -Milliseconds 200
    for ($i = $activeFlutterJobs.Count - 1; $i -ge 0; $i--) {
        $state = $activeFlutterJobs[$i].State
        if ($state -ne 'Running' -and $state -ne 'NotStarted') {
            Receive-Job $activeFlutterJobs[$i] 2>&1 | Out-Null
            Remove-Job $activeFlutterJobs[$i] -Force
            $activeFlutterJobs.RemoveAt($i)
            $cleanCompleted++
        }
    }

    $elapsed = (Get-Date) - $cleanStart
    $avg = if ($cleanCompleted -gt 0) { $elapsed.TotalSeconds / $cleanCompleted } else { 0 }
    $eta = [TimeSpan]::FromSeconds(($cleanTotal - $cleanCompleted) * $avg)
    $percent = if ($cleanTotal -gt 0) { ($cleanCompleted / $cleanTotal) * 100 } else { 100 }

    $activeFlutterPaths = ($activeFlutterJobs | Where-Object State -eq 'Running' | Select-Object -ExpandProperty ProjectPath) -join ", "
    if ($activeFlutterPaths.Length -gt 100) { $activeFlutterPaths = $activeFlutterPaths.Substring(0, 97) + "..." }

    Write-Progress `
        -Id 2 `
        -Activity "Cleaning Flutter projects (Parallel $maxParallel Threads)" `
        -Status "$cleanCompleted/$cleanTotal | Elapsed $($elapsed.ToString('mm\:ss')) | ETA $($eta.ToString('mm\:ss'))" `
        -CurrentOperation "Finishing... Active: $activeFlutterPaths" `
        -PercentComplete $percent
}

    Write-Progress -Id 2 -Completed

    $totalTime = (Get-Date) - $cleanStart
    
    Write-Host "`n=====================================================" -ForegroundColor Green
    Write-Host "🎉 AIO Bulk Cleaner Complete!" -ForegroundColor Green
    Write-Host "=====================================================" -ForegroundColor Green
    Write-Host "Time taken : $($totalTime.ToString('mm\:ss'))"
    Write-Host "Directories: $scanCount scanned"
    Write-Host "Space Freed: $(Format-Bytes $totalFreedBytes)"
    Write-Host "Cleaned    : $cleanTotal Flutter projects"
    
    if ($failedDeletions.Count -gt 0) {
        Write-Host "`n⚠️  WARNING: $($failedDeletions.Count) folders could not be deleted due to permission/lock errors:" -ForegroundColor Yellow
        foreach ($f in $failedDeletions) {
            Write-Host "  - $f" -ForegroundColor DarkGray
        }
    }
    
    Write-Host ""
}
