# Duplicate Finder -- local web app.
# Starts a tiny local server (no internet, no external dependencies) and opens a page in your
# browser where you choose folders or individual files to scan, and delete selected duplicates
# (moved to the Recycle Bin, never permanent).
#
# Keep this PowerShell window open while using the page -- it's the engine behind it.
# Close the window (or press Ctrl+C) to stop the server.

Add-Type -AssemblyName System.Web

# ---------- Shared helpers (main thread) ----------

function Get-Preset {
    $userHome = $env:USERPROFILE
    $oneDrive = $env:OneDrive
    if (-not $oneDrive) { $oneDrive = Join-Path $userHome 'OneDrive' }

    # Prefer the local copy of each known folder. Only fall back to the OneDrive-redirected
    # path when there is no local folder at all (e.g. Desktop, which some setups redirect
    # entirely) -- so OneDrive is never offered as a second, duplicate option.
    $names = @('Desktop', 'Downloads', 'Documents', 'Pictures', 'Music', 'Videos')
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $out = New-Object System.Collections.Generic.List[object]

    foreach ($name in $names) {
        $local = Join-Path $userHome $name
        $cloud = Join-Path $oneDrive $name
        $p = if (Test-Path -LiteralPath $local) { $local } elseif (Test-Path -LiteralPath $cloud) { $cloud } else { $null }
        if ($p -and $seen.Add((Resolve-Path -LiteralPath $p).ProviderPath)) {
            $out.Add([pscustomobject]@{ label = $name; path = $p; kind = 'preset' })
        }
    }

    return $out
}

function Get-BrowseListing {
    param([string]$Path, [bool]$IncludeFiles)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $drives = [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady -and $_.DriveType -in @('Fixed', 'Removable') }
        $dirs = @($drives | ForEach-Object { [pscustomobject]@{ name = $_.Name; path = $_.RootDirectory.FullName } })
        return [pscustomobject]@{ path = ''; parent = $null; dirs = $dirs; files = @(); error = $null }
    }

    try {
        $dirNames = [System.IO.Directory]::GetDirectories($Path)
    } catch {
        return [pscustomobject]@{ path = $Path; parent = (Split-Path $Path -Parent); dirs = @(); files = @(); error = $_.Exception.Message }
    }

    $dirs = @($dirNames | Sort-Object | ForEach-Object { [pscustomobject]@{ name = (Split-Path $_ -Leaf); path = $_ } })

    $files = @()
    if ($IncludeFiles) {
        try {
            $files = @([System.IO.Directory]::GetFiles($Path) | Sort-Object | ForEach-Object {
                [pscustomobject]@{ name = (Split-Path $_ -Leaf); path = $_ }
            })
        } catch { Write-Verbose "Can't list the files in ${Path}: $($_.Exception.Message)" }
    }

    $parent = Split-Path $Path -Parent
    return [pscustomobject]@{ path = $Path; parent = $parent; dirs = $dirs; files = $files; error = $null }
}

# ---------- Background worker: full duplicate scan ----------

$ScanWorkerScript = {
    param($Folders, $State)

    $ExcludeDirNames = @('node_modules', '.git', '__pycache__', 'venv', '.venv')
    $FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS = 0x00400000
    $FILE_ATTRIBUTE_OFFLINE = 0x00001000
    $ignoreCase = [System.StringComparer]::OrdinalIgnoreCase

    function Test-IsCloudOnly {
        param($Attributes)
        $raw = [int]$Attributes
        return (($raw -band $FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS) -ne 0) -or (($raw -band $FILE_ATTRIBUTE_OFFLINE) -ne 0)
    }

    function Invoke-Walk {
        param([string]$RootPath, $AllDirs, $AllFiles)
        $stack = New-Object System.Collections.Generic.Stack[string]
        if (Test-Path -LiteralPath $RootPath -PathType Leaf) {
            $AllFiles.Add($RootPath)
            return
        }
        $stack.Push($RootPath)
        $AllDirs.Add($RootPath)
        while ($stack.Count -gt 0) {
            $current = $stack.Pop()
            try { $dirs = [System.IO.Directory]::GetDirectories($current) } catch { $dirs = @() }
            foreach ($d in $dirs) {
                $name = Split-Path $d -Leaf
                if ($ExcludeDirNames -notcontains $name) {
                    $AllDirs.Add($d)
                    $stack.Push($d)
                }
            }
            try { $files = [System.IO.Directory]::GetFiles($current) } catch { $files = @() }
            foreach ($f in $files) { $AllFiles.Add($f) }
        }
    }

    function Get-Md5Hash {
        param([string]$Path)
        try {
            $md5 = [System.Security.Cryptography.MD5]::Create()
            try {
                $stream = [System.IO.File]::OpenRead($Path)
                try { $bytes = $md5.ComputeHash($stream) } finally { $stream.Dispose() }
            } finally { $md5.Dispose() }
            return [System.BitConverter]::ToString($bytes).Replace('-', '')
        } catch {
            return $null
        }
    }

    try {
        $State.Phase = 'walking'
        # A location may be chosen twice, or one chosen location may sit inside another.
        # Sets prevent one physical path from being reported as a duplicate of itself.
        $allDirs = New-Object 'System.Collections.Generic.HashSet[string]' $ignoreCase
        $allFiles = New-Object 'System.Collections.Generic.HashSet[string]' $ignoreCase
        foreach ($folder in $Folders) {
            if (Test-Path -LiteralPath $folder) {
                Invoke-Walk -RootPath $folder -AllDirs $allDirs -AllFiles $allFiles
                $State.FilesFound = $allFiles.Count
            }
        }

        $State.Phase = 'reading-sizes'
        $fileSize = New-Object 'System.Collections.Generic.Dictionary[string,int64]' $ignoreCase
        $sizeMap = @{}
        $totalFiles = 0
        $skippedCloudOnly = 0

        foreach ($file in $allFiles) {
            try { $item = Get-Item -LiteralPath $file -ErrorAction Stop } catch { continue }
            if (Test-IsCloudOnly -Attributes $item.Attributes) { $skippedCloudOnly++; continue }
            $fileSize[$file] = $item.Length
            if (-not $sizeMap.ContainsKey($item.Length)) { $sizeMap[$item.Length] = New-Object System.Collections.Generic.List[string] }
            $sizeMap[$item.Length].Add($file)
            $totalFiles++
            $State.FilesRead = $totalFiles
        }
        $State.SkippedCloudOnly = $skippedCloudOnly

        $candidateGroups = @($sizeMap.GetEnumerator() | Where-Object { $_.Value.Count -gt 1 })
        $candidateCount = 0
        foreach ($g in $candidateGroups) { $candidateCount += $g.Value.Count }
        $State.HashTotal = $candidateCount

        $State.Phase = 'hashing'
        $hashMap = @{}
        $hashedSoFar = 0
        foreach ($group in $candidateGroups) {
            foreach ($path in $group.Value) {
                $hash = Get-Md5Hash -Path $path
                $hashedSoFar++
                $State.Hashed = $hashedSoFar
                if ($hash) {
                    if (-not $hashMap.ContainsKey($hash)) { $hashMap[$hash] = New-Object System.Collections.Generic.List[string] }
                    $hashMap[$hash].Add($path)
                }
            }
        }

        $duplicateHashGroups = @($hashMap.GetEnumerator() | Where-Object { $_.Value.Count -gt 1 })

        $State.Phase = 'folder-matching'
        $fileToDupHash = New-Object 'System.Collections.Generic.Dictionary[string,string]' $ignoreCase
        foreach ($group in $duplicateHashGroups) {
            foreach ($path in $group.Value) { $fileToDupHash[$path] = $group.Key }
        }

        $filesByParent = New-Object 'System.Collections.Generic.Dictionary[string,System.Collections.Generic.List[string]]' $ignoreCase
        foreach ($f in $allFiles) {
            $parent = Split-Path $f -Parent
            if (-not $filesByParent.ContainsKey($parent)) { $filesByParent[$parent] = New-Object System.Collections.Generic.List[string] }
            $filesByParent[$parent].Add($f)
        }

        $dirsByParent = New-Object 'System.Collections.Generic.Dictionary[string,System.Collections.Generic.List[string]]' $ignoreCase
        foreach ($d in $allDirs) {
            $parent = Split-Path $d -Parent
            if ($parent) {
                if (-not $dirsByParent.ContainsKey($parent)) { $dirsByParent[$parent] = New-Object System.Collections.Generic.List[string] }
                $dirsByParent[$parent].Add($d)
            }
        }

        $dirSignature = New-Object 'System.Collections.Generic.Dictionary[string,string]' $ignoreCase
        foreach ($dir in ($allDirs | Sort-Object Length -Descending)) {
            $matched = $true
            $parts = New-Object System.Collections.Generic.List[string]

            if ($filesByParent.ContainsKey($dir)) {
                foreach ($f in $filesByParent[$dir]) {
                    if ($fileToDupHash.ContainsKey($f)) {
                        $parts.Add("F:" + (Split-Path $f -Leaf) + ":" + $fileToDupHash[$f])
                    } else {
                        $matched = $false
                    }
                }
            }

            if ($matched -and $dirsByParent.ContainsKey($dir)) {
                foreach ($sd in $dirsByParent[$dir]) {
                    if ($dirSignature.ContainsKey($sd)) {
                        $parts.Add("D:" + (Split-Path $sd -Leaf) + ":" + $dirSignature[$sd])
                    } else {
                        $matched = $false
                    }
                }
            }

            if ($matched -and $parts.Count -gt 0) {
                $dirSignature[$dir] = (($parts | Sort-Object) -join "|")
            }
        }

        $allDupDirs = New-Object 'System.Collections.Generic.HashSet[string]' $ignoreCase
        $sigGroups = $dirSignature.GetEnumerator() | Group-Object Value | Where-Object { $_.Count -gt 1 }
        foreach ($g in $sigGroups) { foreach ($entry in $g.Group) { [void]$allDupDirs.Add($entry.Key) } }

        function Get-FolderTotalSize {
            param([string]$Dir)
            $total = 0L
            if ($filesByParent.ContainsKey($Dir)) {
                foreach ($f in $filesByParent[$Dir]) { if ($fileSize.ContainsKey($f)) { $total += $fileSize[$f] } }
            }
            if ($dirsByParent.ContainsKey($Dir)) {
                foreach ($sd in $dirsByParent[$Dir]) { $total += (Get-FolderTotalSize -Dir $sd) }
            }
            return $total
        }

        $folderResults = New-Object System.Collections.Generic.List[object]
        foreach ($g in $sigGroups) {
            $topMembers = @($g.Group | Where-Object {
                $parent = Split-Path $_.Key -Parent
                -not $allDupDirs.Contains($parent)
            } | ForEach-Object { $_.Key })

            if ($topMembers.Count -ge 2) {
                $sizeEach = Get-FolderTotalSize -Dir $topMembers[0]
                $folderResults.Add([pscustomobject]@{
                    type   = 'Folder'
                    paths  = $topMembers
                    size   = $sizeEach
                    wasted = $sizeEach * ($topMembers.Count - 1)
                })
            }
        }

        $coveredPrefixes = @($folderResults | ForEach-Object { $_.paths } | ForEach-Object { $_ + '\' })
        function Test-UnderCoveredFolder {
            param([string]$Path)
            foreach ($prefix in $coveredPrefixes) {
                if ($Path.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
            }
            return $false
        }

        $fileResults = New-Object System.Collections.Generic.List[object]
        foreach ($group in $duplicateHashGroups) {
            $remaining = @($group.Value | Where-Object { -not (Test-UnderCoveredFolder -Path $_) })
            if ($remaining.Count -ge 2) {
                $size = $fileSize[$remaining[0]]
                $fileResults.Add([pscustomobject]@{
                    type   = 'File'
                    paths  = $remaining
                    size   = $size
                    wasted = $size * ($remaining.Count - 1)
                })
            }
        }

        $allResults = @(@($folderResults + $fileResults) | Sort-Object -Property wasted -Descending)
        $totalWasted = ($allResults | Measure-Object -Property wasted -Sum).Sum
        if (-not $totalWasted) { $totalWasted = 0 }

        $State.Result = [pscustomobject]@{
            totalWasted  = $totalWasted
            folderCount  = $folderResults.Count
            fileCount    = $fileResults.Count
            items        = $allResults
        }
        $State.Phase = 'done'
        $State.Status = 'done'
    } catch {
        $State.Status = 'error'
        $State.Error = "$($_.Exception.Message) @ line $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"
    }
}

# ---------- HTTP plumbing ----------

function Write-JsonResponse {
    param($Response, $Data, [int]$StatusCode = 200)
    # -InputObject (not a pipe) so a single-element collection isn't unwrapped to a bare object.
    $json = ConvertTo-Json -InputObject $Data -Depth 12 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $Response.StatusCode = $StatusCode
    $Response.ContentType = 'application/json; charset=utf-8'
    $Response.ContentLength64 = $bytes.Length
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
}

function Write-HtmlResponse {
    param($Response, [string]$Html)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Html)
    $Response.ContentType = 'text/html; charset=utf-8'
    $Response.ContentLength64 = $bytes.Length
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
}

function Read-JsonBody {
    param($Request)
    $reader = New-Object System.IO.StreamReader($Request.InputStream, $Request.ContentEncoding)
    $text = $reader.ReadToEnd()
    $reader.Close()
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return $text | ConvertFrom-Json
}

$script:Jobs = [hashtable]::Synchronized(@{})
$script:JobHandles = @{}
$script:JobCounter = 0

function Invoke-BackgroundJob {
    param([scriptblock]$Script, [object[]]$ArgList)
    $script:JobCounter++
    $id = "job$($script:JobCounter)"
    $state = [hashtable]::Synchronized(@{ Status = 'running'; Phase = 'starting'; Error = $null; Result = $null })
    $script:Jobs[$id] = $state

    $ps = [powershell]::Create()
    [void]$ps.AddScript($Script)
    foreach ($a in $ArgList) { [void]$ps.AddArgument($a) }
    [void]$ps.AddArgument($state)
    $handle = $ps.BeginInvoke()
    $script:JobHandles[$id] = @{ PS = $ps; Handle = $handle }
    return $id
}

# ---------- Front-end (single page app) ----------

$Html = @'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Duplicate Finder</title>
<style>
  :root {
    color-scheme: light dark;
    --bg: #f5f6f8; --card: #ffffff; --text: #1a1d23; --muted: #6b7280;
    --border: #e3e5e8; --accent: #2f6feb; --accent-bg: #eaf0ff; --danger: #d64545; --danger-bg: #fdecec;
    --folder-badge: #eef2ff; --folder-text: #4338ca;
    --file-badge: #f0fdf4; --file-text: #15803d;
    --ok-bg: #f0fdf4; --ok-text: #15803d;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #14161a; --card: #1d2026; --text: #e8eaed; --muted: #9aa0a6;
      --border: #2c2f36; --accent: #6c9bff; --accent-bg: #1c2540; --danger: #ff6b6b; --danger-bg: #3a1f1f;
      --folder-badge: #26264a; --folder-text: #a5b4fc;
      --file-badge: #1c3324; --file-text: #86efac;
      --ok-bg: #1c3324; --ok-text: #86efac;
    }
  }
  :root[data-theme="light"] {
    --bg: #f5f6f8; --card: #ffffff; --text: #1a1d23; --muted: #6b7280;
    --border: #e3e5e8; --accent: #2f6feb; --accent-bg: #eaf0ff; --danger: #d64545; --danger-bg: #fdecec;
    --folder-badge: #eef2ff; --folder-text: #4338ca; --file-badge: #f0fdf4; --file-text: #15803d;
    --ok-bg: #f0fdf4; --ok-text: #15803d;
  }
  :root[data-theme="dark"] {
    --bg: #14161a; --card: #1d2026; --text: #e8eaed; --muted: #9aa0a6;
    --border: #2c2f36; --accent: #6c9bff; --accent-bg: #1c2540; --danger: #ff6b6b; --danger-bg: #3a1f1f;
    --folder-badge: #26264a; --folder-text: #a5b4fc; --file-badge: #1c3324; --file-text: #86efac;
    --ok-bg: #1c3324; --ok-text: #86efac;
  }
  * { box-sizing: border-box; }
  body { margin: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Arial, sans-serif; background: radial-gradient(circle at top left, var(--accent-bg), var(--bg) 38%); color: var(--text); padding-bottom: 82px; }
  header { position: sticky; top: 0; background: color-mix(in srgb, var(--bg) 88%, transparent); backdrop-filter: blur(12px); z-index: 10; padding: 22px 32px 16px; border-bottom: 1px solid var(--border); display: flex; align-items: flex-start; justify-content: space-between; gap: 16px; }
  h1 { font-size: 28px; letter-spacing: -.03em; margin: 0 0 4px; }
  .subtitle { font-size: 14px; color: var(--muted); }
  .theme-toggle { white-space: nowrap; }
  main { padding: 30px 32px; max-width: 1320px; margin: 0 auto; }
  .view { display: none; }
  .view.active { display: block; }
  .card { background: color-mix(in srgb, var(--card) 94%, transparent); border: 1px solid var(--border); box-shadow: 0 14px 32px rgba(25, 35, 55, .08); border-radius: 18px; padding: 28px; margin-bottom: 18px; }
  .card h2 { font-size: 20px; letter-spacing: -.02em; margin: 0 0 14px; }
  .chips { display: flex; gap: 9px; flex-wrap: wrap; margin: 14px 0; min-height: 0; }
  .chip { background: var(--accent-bg); color: var(--accent); border-radius: 20px; padding: 8px 13px; font-size: 14px; display: flex; align-items: center; gap: 8px; }
  .chip button { border: none; background: none; color: inherit; cursor: pointer; font-weight: bold; padding: 0; }
  label.preset { display: inline-flex; align-items: center; gap: 7px; margin: 5px 14px 5px 0; font-size: 14px; }
  .browser { border: 1px solid var(--border); border-radius: 14px; padding: 14px; margin-top: 12px; background: var(--bg); }
  .browser .path-bar { display: flex; gap: 10px; margin-bottom: 0; }
  .browser .path-bar input { flex: 1; min-width: 220px; padding: 12px 14px; border-radius: 10px; border: 1px solid var(--border); background: var(--card); color: var(--text); font-size: 15px; }
  .browser .entries { max-height: 380px; overflow-y: auto; margin-top: 12px; padding-right: 4px; }
  .browser .entries.hidden { display: none; }
  .entry-row { display: flex; align-items: center; gap: 10px; padding: 10px 12px; font-size: 14px; border-radius: 9px; cursor: pointer; }
  .entry-row:hover { background: var(--accent-bg); }
  .entry-row.selected { outline: 2px solid var(--accent); background: var(--accent-bg); }
  .entry-row .name { flex: 1; cursor: pointer; }
  .entry-row.file .name { color: var(--muted); }
  input[type=text] { padding: 9px 12px; border-radius: 8px; border: 1px solid var(--border); background: var(--card); color: var(--text); font-size: 14px; }
  select, button { padding: 10px 14px; border-radius: 10px; border: 1px solid var(--border); background: var(--card); color: var(--text); font-size: 14px; cursor: pointer; }
  button.primary { background: var(--accent); color: white; border: none; }
  button.danger { background: var(--danger-bg); color: var(--danger); border: 1px solid var(--danger); }
  button:disabled { opacity: 0.5; cursor: not-allowed; }
  button.small { padding: 7px 11px; font-size: 13px; }
  .browse-button { min-width: 102px; }
  .add-path-button { min-width: 145px; font-weight: 650; }
  .browser-selection { margin: 10px 2px 0; color: var(--muted); font-size: 13px; }
  .row { display: flex; gap: 10px; align-items: center; flex-wrap: wrap; }
  .progress-box { text-align: center; padding: 40px 0; }
  .progress-box .phase { font-size: 16px; margin-bottom: 10px; }
  .progress-box .counts { color: var(--muted); font-size: 13px; }
  .stats { display: flex; gap: 24px; flex-wrap: wrap; margin: 12px 0; }
  .stat { background: var(--card); border: 1px solid var(--border); border-radius: 10px; padding: 10px 16px; min-width: 140px; }
  .stat .num { font-size: 22px; font-weight: 700; }
  .stat .label { font-size: 12px; color: var(--muted); }
  .controls { display: flex; gap: 10px; flex-wrap: wrap; align-items: center; margin: 10px 0; }
  .controls input[type=text] { flex: 1; min-width: 220px; }
  .group { background: var(--card); border: 1px solid var(--border); border-radius: 10px; margin-bottom: 10px; overflow: hidden; }
  .group-head { display: flex; align-items: center; gap: 12px; padding: 12px 16px; cursor: pointer; }
  .badge { font-size: 11px; font-weight: 700; padding: 3px 8px; border-radius: 6px; text-transform: uppercase; letter-spacing: .03em; }
  .badge.folder { background: var(--folder-badge); color: var(--folder-text); }
  .badge.file { background: var(--file-badge); color: var(--file-text); }
  .wasted { font-weight: 700; white-space: nowrap; }
  .copies { color: var(--muted); font-size: 13px; white-space: nowrap; }
  .first-path { color: var(--muted); font-size: 13px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; flex: 1; }
  .chevron { transition: transform .15s; color: var(--muted); }
  .group.open .chevron { transform: rotate(90deg); }
  .paths { display: none; }
  .group.open .paths { display: block; }
  .path-row { display: flex; align-items: center; gap: 10px; padding: 9px 16px; font-family: Consolas, monospace; font-size: 13px; border-top: 1px solid var(--border); }
  .path-row span.p { flex: 1; word-break: break-all; }
  .path-row button { padding: 4px 10px; font-size: 12px; }
  .keep-tag { font-size: 11px; color: var(--muted); border: 1px solid var(--border); border-radius: 6px; padding: 2px 6px; white-space: nowrap; }
  .status-tag { font-size: 11px; border-radius: 6px; padding: 2px 6px; white-space: nowrap; }
  .status-tag.ok { background: var(--ok-bg); color: var(--ok-text); }
  .status-tag.fail { background: var(--danger-bg); color: var(--danger); }
  footer.bar { position: fixed; bottom: 0; left: 0; right: 0; background: var(--card); border-top: 1px solid var(--border); padding: 12px 24px; display: flex; align-items: center; justify-content: space-between; gap: 16px; }
  .note { font-size: 13px; line-height: 1.45; color: var(--muted); max-width: 720px; }
  .empty { text-align: center; color: var(--muted); padding: 40px; }
</style>
</head>
<body>
<header>
  <div>
    <h1>Duplicate Finder</h1>
    <div class="subtitle">Keep this window's PowerShell process running while you use the page.</div>
  </div>
  <button class="theme-toggle" id="themeToggle" type="button">Toggle theme</button>
</header>
<main>

  <div class="view active" id="view-setup">
    <div class="card" id="scan-setup">
      <h2>Locations to scan</h2>
      <div id="presetList"></div>
      <div class="chips" id="scanChips"></div>
      <div class="note">Use Browse to add a specific folder or file. Your selection stays listed above until you remove it.</div>
      <div id="scanBrowser"></div>
      <div class="row" style="margin-top:12px;">
        <button class="primary" id="startScanBtn" disabled>Start scan</button>
      </div>
    </div>
  </div>

  <div class="view" id="view-progress">
    <div class="progress-box">
      <div class="phase" id="progressPhase">Working...</div>
      <div class="counts" id="progressCounts"></div>
    </div>
  </div>

  <div class="view" id="view-results">
    <div class="stats" id="resultStats"></div>
    <div class="controls">
      <input type="text" id="search" placeholder="Filter by path...">
      <select id="sortBy">
        <option value="wasted">Sort: space wasted</option>
        <option value="count">Sort: number of copies</option>
        <option value="path">Sort: path (A-Z)</option>
      </select>
      <select id="typeFilter">
        <option value="">All types</option>
        <option value="Folder">Folders only</option>
        <option value="File">Files only</option>
      </select>
      <button id="backBtn">&larr; New search</button>
    </div>
    <div id="list"></div>
  </div>

</main>
<footer class="bar">
  <div class="note">Checking a box only marks it here. Nothing is deleted until you click the button and confirm. Deleted items go to the Recycle Bin (not permanently deleted).</div>
  <button class="danger" id="deleteBtn" disabled>Delete selected (0)</button>
</footer>
<script>
const SESSION_TOKEN = '__SESSION_TOKEN__';
let currentData = [];
let selected = new Set();
let scanTargets = new Set();
let activeJobId = null;

// Every API call carries the session token; the server rejects calls without it.
function api(url, options = {}) {
  options.headers = Object.assign({}, options.headers, { 'X-Session-Token': SESSION_TOKEN });
  return fetch(url, options);
}

// Paths and file names are shown as text, never as HTML.
function esc(value) {
  return String(value).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

function fmtBytes(b) {
  const units = ['B','KB','MB','GB','TB'];
  let i = 0;
  while (b >= 1024 && i < units.length - 1) { b /= 1024; i++; }
  return b.toFixed(2) + ' ' + units[i];
}

function showView(id) {
  document.querySelectorAll('.view').forEach(v => v.classList.remove('active'));
  document.getElementById(id).classList.add('active');
}

// ---------- Presets ----------

async function loadPresets() {
  const res = await api('/api/presets');
  const presets = await res.json();
  const container = document.getElementById('presetList');
  container.innerHTML = presets.map(p => `
    <label class="preset"><input type="checkbox" data-path="${encodeURIComponent(p.path)}"> ${esc(p.label)} <span style="color:var(--muted);font-size:11px;">${esc(p.path)}</span></label>
  `).join('');
  container.querySelectorAll('input[type=checkbox]').forEach(cb => cb.addEventListener('change', () => onPresetToggle(cb)));
}

function setTheme(theme) {
  document.documentElement.dataset.theme = theme;
  localStorage.setItem('duplicateFinderTheme', theme);
  document.getElementById('themeToggle').textContent = theme === 'dark' ? 'Light mode' : 'Dark mode';
}

const savedTheme = localStorage.getItem('duplicateFinderTheme');
const initialTheme = savedTheme || (window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light');
setTheme(initialTheme);
document.getElementById('themeToggle').addEventListener('click', () => {
  setTheme(document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark');
});

function onPresetToggle(cb) {
  const path = decodeURIComponent(cb.getAttribute('data-path'));
  if (cb.checked) scanTargets.add(path); else scanTargets.delete(path);
  renderChips();
}

function renderChips() {
  const container = document.getElementById('scanChips');
  container.innerHTML = Array.from(scanTargets).map(p => `
    <span class="chip">${esc(p)} <button type="button" data-path="${encodeURIComponent(p)}">&times;</button></span>
  `).join('');
  container.querySelectorAll('button[data-path]').forEach(btn => btn.addEventListener('click', () => removeTarget(btn.getAttribute('data-path'))));
  document.getElementById('startScanBtn').disabled = scanTargets.size === 0;
}

function removeTarget(encPath) {
  const path = decodeURIComponent(encPath);
  scanTargets.delete(path);
  renderChips();
  document.querySelectorAll('#presetList input').forEach(cb => {
    if (decodeURIComponent(cb.getAttribute('data-path')) === path) cb.checked = false;
  });
}

// ---------- Folder/file browser ----------

function makeBrowser(containerId, opts) {
  const container = document.getElementById(containerId);
  let currentPath = '';
  let selectedPath = '';
  let browserOpen = false;

  async function load(path) {
    currentPath = path;
    selectedPath = path;
    const filesParam = opts.includeFiles ? '&files=1' : '';
    const res = await api('/api/browse?path=' + encodeURIComponent(path || '') + filesParam);
    const data = await res.json();
    container.innerHTML = `
      <div class="browser">
        <div class="path-bar">
          <input type="text" value="${esc(data.path || '')}" placeholder="Paste or type a folder/file path, then add it" id="${containerId}-input">
          <button class="browse-button" id="${containerId}-browse">Browse</button>
          <button class="primary add-path-button" id="${containerId}-add">Add this path</button>
        </div>
        <div class="browser-selection" id="${containerId}-selection">${selectedPath ? `Selected: ${esc(selectedPath)}` : 'Select a drive, folder, or file.'}</div>
        <div class="entries ${browserOpen ? '' : 'hidden'}" id="${containerId}-entries">
          ${data.error ? `<div class="note">Can't list this folder: ${esc(data.error)}</div>` : ''}
          ${data.parent ? `<div class="entry-row dir" data-path="${encodeURIComponent(data.parent)}"><span>&#8592;</span><span class="name">Up one level</span></div>` : ''}
          ${(data.dirs || []).map(d => `<div class="entry-row dir" data-path="${encodeURIComponent(d.path)}"><span>&#128193;</span><span class="name">${esc(d.name)}</span></div>`).join('')}
          ${opts.includeFiles ? (data.files || []).map(f => `
            <div class="entry-row file" data-path="${encodeURIComponent(f.path)}"><span>&#128196;</span><span class="name">${esc(f.name)}</span></div>`).join('') : ''}
        </div>
      </div>
    `;
    const input = document.getElementById(containerId + '-input');
    const selection = document.getElementById(containerId + '-selection');
    const setSelection = (path, row) => {
      selectedPath = path;
      input.value = path;
      selection.textContent = 'Selected: ' + path;
      container.querySelectorAll('.entry-row').forEach(el => el.classList.remove('selected'));
      if (row) row.classList.add('selected');
    };
    container.querySelectorAll('.entry-row.dir').forEach(row => {
      row.addEventListener('click', () => load(decodeURIComponent(row.getAttribute('data-path'))));
    });
    container.querySelectorAll('.entry-row.file').forEach(row => {
      row.addEventListener('click', () => setSelection(decodeURIComponent(row.getAttribute('data-path')), row));
    });
    document.getElementById(containerId + '-browse').addEventListener('click', () => {
      browserOpen = !browserOpen;
      document.getElementById(containerId + '-entries').classList.toggle('hidden', !browserOpen);
    });
    document.getElementById(containerId + '-add').addEventListener('click', () => {
      const path = input.value.trim() || selectedPath || currentPath;
      if (path) opts.onAddPath(path);
    });
    input.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') {
        e.preventDefault();
        const path = input.value.trim();
        if (path) load(path);
      }
    });
  }

  load('');
}

makeBrowser('scanBrowser', {
  includeFiles: true,
  onAddPath: (path) => { scanTargets.add(path); renderChips(); }
});

// ---------- Start scan ----------

document.getElementById('startScanBtn').addEventListener('click', async () => {
  const res = await api('/api/scan/start', {
    method: 'POST', headers: {'Content-Type':'application/json'},
    body: JSON.stringify({ folders: Array.from(scanTargets) })
  });
  const data = await res.json();
  activeJobId = data.id;
  showView('view-progress');
  pollProgress();
});

async function pollProgress() {
  const res = await api('/api/job/progress?id=' + encodeURIComponent(activeJobId));
  const s = await res.json();

  const phaseLabel = { walking: 'Scanning folders...', 'reading-sizes': 'Reading file sizes...', hashing: 'Comparing file contents...', 'folder-matching': 'Looking for duplicated folders...', done: 'Done' }[s.phase] || s.phase;
  document.getElementById('progressPhase').textContent = phaseLabel;
  let counts = `${s.filesFound || 0} files found`;
  if (s.filesRead) counts += ` &middot; ${s.filesRead} read`;
  if (s.hashTotal) counts += ` &middot; hashed ${s.hashed || 0}/${s.hashTotal}`;
  document.getElementById('progressCounts').innerHTML = counts;

  if (s.status === 'error') {
    document.getElementById('progressPhase').textContent = 'Something went wrong: ' + s.error;
    return;
  }
  if (s.status === 'done') {
    showScanResults(s.result);
    return;
  }
  setTimeout(pollProgress, 700);
}

document.getElementById('backBtn').addEventListener('click', () => { showView('view-setup'); selected.clear(); updateFooter(); });

// ---------- Results ----------

function showScanResults(result) {
  currentData = (result.items || []).map(it => ({ type: it.type, size: it.size, wasted: it.wasted, paths: it.paths }));
  document.getElementById('resultStats').innerHTML = `
    <div class="stat"><div class="num">${fmtBytes(result.totalWasted || 0)}</div><div class="label">Space you could free</div></div>
    <div class="stat"><div class="num">${result.folderCount || 0}</div><div class="label">Duplicate folder sets</div></div>
    <div class="stat"><div class="num">${result.fileCount || 0}</div><div class="label">Duplicate file sets</div></div>
  `;
  selected.clear();
  showView('view-results');
  render();
}

function render() {
  const q = document.getElementById('search').value.toLowerCase();
  const sortBy = document.getElementById('sortBy').value;
  const typeFilter = document.getElementById('typeFilter').value;

  let items = currentData.filter(d => {
    if (typeFilter && d.type !== typeFilter) return false;
    if (!q) return true;
    return d.paths.some(p => p.toLowerCase().includes(q));
  });

  items = items.slice().sort((a, b) => {
    if (sortBy === 'wasted') return b.wasted - a.wasted;
    if (sortBy === 'count') return b.paths.length - a.paths.length;
    if (sortBy === 'path') return a.paths[0].localeCompare(b.paths[0]);
    return 0;
  });

  const list = document.getElementById('list');
  list.innerHTML = '';

  if (items.length === 0) {
    list.innerHTML = '<div class="empty">No matches.</div>';
    return;
  }

  items.forEach(d => {
    const div = document.createElement('div');
    div.className = 'group';
    const badgeClass = d.type === 'Folder' ? 'folder' : 'file';
    div.innerHTML = `
      <div class="group-head">
        <span class="chevron">&#9656;</span>
        <span class="badge ${badgeClass}">${esc(d.type)}</span>
        <span class="wasted">${fmtBytes(d.wasted)} wasted</span>
        <span class="copies">${d.paths.length} location(s)</span>
        <span class="first-path">${esc(d.paths[0])}</span>
      </div>
      <div class="paths">
        ${d.paths.map(p => `
          <div class="path-row" data-path="${encodeURIComponent(p)}">
            <input type="checkbox" data-path="${encodeURIComponent(p)}">
            <span class="p">${esc(p)}</span>
            <button type="button" class="reveal" data-path="${encodeURIComponent(p)}">Show in Explorer</button>
          </div>
        `).join('')}
      </div>
    `;
    div.querySelector('.group-head').addEventListener('click', () => div.classList.toggle('open'));
    div.querySelectorAll('.paths input[type=checkbox]').forEach(cb => cb.addEventListener('click', () => toggleSelect(cb)));
    div.querySelectorAll('button.reveal').forEach(btn => btn.addEventListener('click', ev => revealPath(ev, btn.getAttribute('data-path'))));
    list.appendChild(div);
  });
}

function toggleSelect(cb) {
  const path = decodeURIComponent(cb.getAttribute('data-path'));
  const groupEl = cb.closest('.paths');
  const boxes = Array.from(groupEl.querySelectorAll('input[type=checkbox]'));
  const checkedCount = boxes.filter(b => b.checked).length;
  if (cb.checked && checkedCount === boxes.length) {
    cb.checked = false;
    alert('At least one copy has to stay -- uncheck another one in this group first.');
    return;
  }
  if (cb.checked) selected.add(path); else selected.delete(path);
  updateFooter();
}

function revealPath(ev, encPath) {
  ev.stopPropagation();
  const path = decodeURIComponent(encPath);
  const btn = ev.target;
  const old = btn.textContent;
  api('/api/reveal', { method: 'POST', headers: {'Content-Type':'application/json'}, body: JSON.stringify({ path }) })
    .then(r => r.json())
    .then(data => {
      if (!data.ok) {
        btn.textContent = data.error || 'Not found';
        setTimeout(() => { btn.textContent = old; }, 1500);
      }
    })
    .catch(() => {
      btn.textContent = 'Failed';
      setTimeout(() => { btn.textContent = old; }, 1500);
    });
}

function updateFooter() {
  const btn = document.getElementById('deleteBtn');
  btn.textContent = 'Delete selected (' + selected.size + ')';
  btn.disabled = selected.size === 0;
}

document.getElementById('deleteBtn').addEventListener('click', async () => {
  const paths = Array.from(selected);
  if (paths.length === 0) return;
  if (!confirm(`Move ${paths.length} item(s) to the Recycle Bin?\n\nThis can be undone from the Recycle Bin, but review the list before continuing.`)) return;

  const res = await api('/api/delete', {
    method: 'POST', headers: {'Content-Type':'application/json'},
    body: JSON.stringify({ paths })
  });
  const data = await res.json();

  data.results.forEach(r => {
    const row = document.querySelector(`.path-row[data-path="${encodeURIComponent(r.path)}"]`);
    if (row) {
      const tag = document.createElement('span');
      tag.className = 'status-tag ' + (r.ok ? 'ok' : 'fail');
      tag.textContent = r.ok ? 'Recycled' : ('Failed: ' + r.error);
      row.appendChild(tag);
      if (r.ok) {
        const cb = row.querySelector('input[type=checkbox]');
        cb.disabled = true;
        cb.checked = false;
        selected.delete(r.path);
      }
    }
  });
  updateFooter();
});

document.getElementById('search').addEventListener('input', render);
document.getElementById('sortBy').addEventListener('change', render);
document.getElementById('typeFilter').addEventListener('change', render);

loadPresets();
</script>
</body>
</html>
'@

# ---------- Session token ----------
# Only the page served by this script knows this value. Requests without it, or from another
# site, are rejected, so no other web page can drive the API (for example, /api/delete).
$tokenBytes = New-Object byte[] 32
$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
try { $rng.GetBytes($tokenBytes) } finally { $rng.Dispose() }
$SessionToken = -join ($tokenBytes | ForEach-Object { $_.ToString('x2') })
$PageHtml = $Html.Replace('__SESSION_TOKEN__', $SessionToken)

function Test-ApiRequest {
    param($Request, [int]$Port)
    $origin = $Request.Headers['Origin']
    if ($origin -and $origin -ne "http://localhost:$Port") { return $false }
    return $Request.Headers['X-Session-Token'] -ceq $SessionToken
}

# ---------- Server loop ----------

$port = 8791
$listener = $null
for ($p = $port; $p -lt $port + 10; $p++) {
    try {
        $candidate = New-Object System.Net.HttpListener
        $candidate.Prefixes.Add("http://localhost:$p/")
        $candidate.Start()
        $listener = $candidate
        $port = $p
        break
    } catch {
        continue
    }
}

if (-not $listener) {
    Write-Host "Could not start the local server (no free port found)."
    exit 1
}

Write-Host "Duplicate Finder running at http://localhost:$port/"
Write-Host "Keep this window open while you use the page. Press Ctrl+C to stop."
Start-Process "http://localhost:$port/"

while ($listener.IsListening) {
    $context = $listener.GetContext()
    $request = $context.Request
    $response = $context.Response
    try {
        $path = $request.Url.AbsolutePath
        $method = $request.HttpMethod

        if ($path.StartsWith('/api/') -and -not (Test-ApiRequest -Request $request -Port $port)) {
            Write-JsonResponse -Response $response -Data @{ error = 'forbidden' } -StatusCode 403
        }
        elseif ($method -eq 'GET' -and $path -eq '/') {
            Write-HtmlResponse -Response $response -Html $PageHtml
        }
        elseif ($method -eq 'GET' -and $path -eq '/api/presets') {
            Write-JsonResponse -Response $response -Data (Get-Preset)
        }
        elseif ($method -eq 'GET' -and $path -eq '/api/browse') {
            $qs = [System.Web.HttpUtility]::ParseQueryString($request.Url.Query)
            $reqPath = $qs['path']
            $includeFiles = $qs['files'] -eq '1'
            Write-JsonResponse -Response $response -Data (Get-BrowseListing -Path $reqPath -IncludeFiles $includeFiles)
        }
        elseif ($method -eq 'POST' -and $path -eq '/api/scan/start') {
            $body = Read-JsonBody -Request $request
            $folders = @($body.folders)
            $id = Invoke-BackgroundJob -Script $ScanWorkerScript -ArgList @(, $folders)
            Write-JsonResponse -Response $response -Data @{ id = $id }
        }
        elseif ($method -eq 'GET' -and $path -eq '/api/job/progress') {
            $qs = [System.Web.HttpUtility]::ParseQueryString($request.Url.Query)
            $id = $qs['id']
            if ($script:Jobs.ContainsKey($id)) {
                $state = $script:Jobs[$id]
                $data = @{
                    status = $state.Status; phase = $state.Phase; error = $state.Error
                    filesFound = $state.FilesFound; filesRead = $state.FilesRead
                    hashTotal = $state.HashTotal; hashed = $state.Hashed
                    result = $state.Result
                }
                Write-JsonResponse -Response $response -Data $data
                if ($state.Status -in @('done', 'error') -and $script:JobHandles.ContainsKey($id)) {
                    try {
                        $j = $script:JobHandles[$id]
                        $j.PS.EndInvoke($j.Handle) | Out-Null
                        $j.PS.Dispose()
                    } catch { Write-Verbose "Could not release the finished job ${id}: $($_.Exception.Message)" }
                    $script:JobHandles.Remove($id)
                }
            } else {
                Write-JsonResponse -Response $response -Data @{ status = 'unknown' } -StatusCode 404
            }
        }
        elseif ($method -eq 'POST' -and $path -eq '/api/delete') {
            Add-Type -AssemblyName Microsoft.VisualBasic
            $body = Read-JsonBody -Request $request
            $results = New-Object System.Collections.Generic.List[object]
            foreach ($p in @($body.paths)) {
                try {
                    if (-not (Test-Path -LiteralPath $p)) {
                        $results.Add(@{ path = $p; ok = $false; error = 'Not found' })
                        continue
                    }
                    if (Test-Path -LiteralPath $p -PathType Container) {
                        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($p, 'OnlyErrorDialogs', 'SendToRecycleBin')
                    } else {
                        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($p, 'OnlyErrorDialogs', 'SendToRecycleBin')
                    }
                    $results.Add(@{ path = $p; ok = $true; error = $null })
                } catch {
                    $results.Add(@{ path = $p; ok = $false; error = $_.Exception.Message })
                }
            }
            Write-JsonResponse -Response $response -Data @{ results = $results }
        }
        elseif ($method -eq 'POST' -and $path -eq '/api/reveal') {
            $body = Read-JsonBody -Request $request
            $p = $body.path
            if (-not (Test-Path -LiteralPath $p)) {
                Write-JsonResponse -Response $response -Data @{ ok = $false; error = 'Not found' }
            } else {
                try {
                    Start-Process -FilePath 'explorer.exe' -ArgumentList "/select,`"$p`""
                    Write-JsonResponse -Response $response -Data @{ ok = $true }
                } catch {
                    Write-JsonResponse -Response $response -Data @{ ok = $false; error = $_.Exception.Message }
                }
            }
        }
        else {
            $response.StatusCode = 404
            Write-JsonResponse -Response $response -Data @{ error = 'not found' } -StatusCode 404
        }
    } catch {
        try {
            $response.StatusCode = 500
            Write-JsonResponse -Response $response -Data @{ error = $_.Exception.Message } -StatusCode 500
        } catch { Write-Verbose "Could not send the error response: $($_.Exception.Message)" }
    } finally {
        $response.OutputStream.Close()
    }
}
