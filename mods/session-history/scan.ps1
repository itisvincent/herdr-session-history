# Lists recent agent sessions as one JSON object (array under .sessions).
# Used by the session-history mod. Keep it dependency-free.
param(
  [string]$Scope = "all",   # all | folder
  [string]$Folder = "",
  [int]$Limit = 80,
  [string]$Agents = "pi,claude,codex"
)

$ErrorActionPreference = "Stop"
$wanted = @{}
foreach ($a in ($Agents -split ",") | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ }) {
  $wanted[$a] = $true
}

function Norm([string]$p) {
  if ([string]::IsNullOrWhiteSpace($p)) { return "" }
  try { return [IO.Path]::GetFullPath($p).TrimEnd('\','/').ToLowerInvariant() }
  catch { return $p.TrimEnd('\','/').ToLowerInvariant() }
}

function RelLabel([string]$cwd) {
  if ([string]::IsNullOrWhiteSpace($cwd)) { return "" }
  $name = [IO.Path]::GetFileName($cwd.TrimEnd('\','/'))
  if ($name) { return $name }
  return $cwd
}

function FirstUserText([string]$path, [string]$agent) {
  try {
    $fs = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
  } catch { return "" }
  try {
    $sr = New-Object IO.StreamReader($fs)
    $n = 0
    while (-not $sr.EndOfStream -and $n -lt 80) {
      $line = $sr.ReadLine(); $n++
      if ([string]::IsNullOrWhiteSpace($line)) { continue }
      try { $o = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
      if ($agent -eq "pi") {
        if ($o.type -eq "message" -and $o.message -and $o.message.role -eq "user") {
          $parts = @($o.message.content)
          foreach ($c in $parts) {
            if ($c.type -eq "text" -and $c.text) {
              $t = [string]$c.text
              if ($t.Length -gt 160) { $t = $t.Substring(0, 160) }
              return ($t -replace "\s+", " ").Trim()
            }
          }
        }
      } elseif ($agent -eq "claude") {
        if ($o.type -eq "human" -or ($o.type -eq "user") -or ($o.message -and $o.message.role -eq "user")) {
          $text = $null
          if ($o.message -and $o.message.content) {
            if ($o.message.content -is [string]) { $text = $o.message.content }
            else {
              foreach ($c in @($o.message.content)) {
                if ($c.type -eq "text" -and $c.text) { $text = $c.text; break }
              }
            }
          } elseif ($o.content -is [string]) { $text = $o.content }
          if ($text) {
            $t = [string]$text
            if ($t.Length -gt 160) { $t = $t.Substring(0, 160) }
            return ($t -replace "\s+", " ").Trim()
          }
        }
      } elseif ($agent -eq "codex") {
        if ($o.type -eq "event_msg" -and $o.payload -and $o.payload.type -eq "user_message") {
          $t = [string]($o.payload.message)
          if ($t.Length -gt 160) { $t = $t.Substring(0, 160) }
          return ($t -replace "\s+", " ").Trim()
        }
        if ($o.type -eq "response_item" -and $o.payload -and $o.payload.role -eq "user") {
          $t = [string]($o.payload.content)
          if ($t.Length -gt 160) { $t = $t.Substring(0, 160) }
          return ($t -replace "\s+", " ").Trim()
        }
      }
    }
  } finally { $fs.Dispose() }
  return ""
}

function ReadMeta([string]$path, [string]$agent) {
  $cwd = $null; $id = $null; $preview = ""
  try {
    $fs = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
  } catch { return $null }
  try {
    $sr = New-Object IO.StreamReader($fs)
    $n = 0
    while (-not $sr.EndOfStream -and $n -lt 40) {
      $line = $sr.ReadLine(); $n++
      if ([string]::IsNullOrWhiteSpace($line)) { continue }
      try { $o = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
      if ($agent -eq "pi") {
        if ($o.type -eq "session") {
          if ($o.cwd) { $cwd = [string]$o.cwd }
          if ($o.id) { $id = [string]$o.id }
        }
      } elseif ($agent -eq "claude") {
        if (-not $id -and $o.sessionId) { $id = [string]$o.sessionId }
        if (-not $cwd -and $o.cwd) { $cwd = [string]$o.cwd }
      } elseif ($agent -eq "codex") {
        if ($o.type -eq "session_meta" -and $o.payload) {
          if ($o.payload.id) { $id = [string]$o.payload.id }
          if ($o.payload.cwd) { $cwd = [string]$o.payload.cwd }
        }
        if (-not $id -and $o.session_id) { $id = [string]$o.session_id }
        if (-not $cwd -and $o.cwd) { $cwd = [string]$o.cwd }
      }
      if ($cwd -and $id) { break }
    }
  } finally { $fs.Dispose() }

  if (-not $id) {
    $base = [IO.Path]::GetFileNameWithoutExtension($path)
    if ($agent -eq "pi" -and $base -match '_([0-9a-fA-F-]{8,})$') { $id = $Matches[1] }
    elseif ($agent -eq "claude") { $id = $base }
    else { $id = $base }
  }
  $preview = FirstUserText $path $agent
  return @{ cwd = $cwd; id = $id; preview = $preview }
}

$folderNorm = Norm $Folder
$sessions = New-Object System.Collections.Generic.List[object]

function AddFile([string]$path, [string]$agent) {
  if (-not (Test-Path -LiteralPath $path)) { return }
  $item = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
  if (-not $item -or $item.Length -lt 20) { return }
  $meta = ReadMeta $path $agent
  if (-not $meta) { return }
  $cwd = [string]$meta.cwd
  if ($Scope -eq "folder" -and $folderNorm) {
    $c = Norm $cwd
    if (-not $c) { return }
    if ($c -ne $folderNorm -and -not $c.StartsWith($folderNorm + [IO.Path]::DirectorySeparatorChar) -and -not $c.StartsWith($folderNorm + '/')) { return }
  }
  $argv = @()
  if ($agent -eq "pi") { $argv = @("pi", "--session", $path) }
  elseif ($agent -eq "claude") { $argv = @("claude", "--resume", [string]$meta.id) }
  elseif ($agent -eq "codex") { $argv = @("codex", "resume", [string]$meta.id) }

  $sessions.Add([ordered]@{
    agent = $agent
    id = [string]$meta.id
    path = $path
    cwd = $cwd
    folder = RelLabel $cwd
    preview = [string]$meta.preview
    mtime = [int64]([DateTimeOffset]$item.LastWriteTimeUtc).ToUnixTimeMilliseconds()
    size = [int64]$item.Length
    argv = $argv
  }) | Out-Null
}

# Pi
if ($wanted.ContainsKey("pi")) {
  $piRoot = Join-Path $env:USERPROFILE ".pi\agent\sessions"
  if (Test-Path -LiteralPath $piRoot) {
    Get-ChildItem -LiteralPath $piRoot -Recurse -File -Filter "*.jsonl" -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTimeUtc -Descending |
      Select-Object -First ($Limit * 2) |
      ForEach-Object { AddFile $_.FullName "pi" }
  }
}

# Claude (ReClaude junction or native ~/.claude/projects)
if ($wanted.ContainsKey("claude")) {
  $claudeRoots = @(
    (Join-Path $env:USERPROFILE ".claude\projects"),
    (Join-Path $env:USERPROFILE ".rec\claude\accounts")
  )
  foreach ($root in $claudeRoots) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    $files = @()
    if ($root -like "*\.rec\claude\accounts") {
      Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $proj = Join-Path $_.FullName "config\projects"
        if (Test-Path -LiteralPath $proj) {
          $files += Get-ChildItem -LiteralPath $proj -Recurse -File -Filter "*.jsonl" -ErrorAction SilentlyContinue
        }
      }
    } else {
      $files = Get-ChildItem -LiteralPath $root -Recurse -File -Filter "*.jsonl" -ErrorAction SilentlyContinue
    }
    $files |
      Where-Object { $_.FullName -notmatch '\\subagents\\' } |
      Sort-Object LastWriteTimeUtc -Descending |
      Select-Object -First ($Limit * 2) |
      ForEach-Object { AddFile $_.FullName "claude" }
  }
}

# Codex
if ($wanted.ContainsKey("codex")) {
  $codexRoot = Join-Path $env:USERPROFILE ".codex\sessions"
  if (Test-Path -LiteralPath $codexRoot) {
    Get-ChildItem -LiteralPath $codexRoot -Recurse -File -ErrorAction SilentlyContinue |
      Where-Object { $_.Extension -in ".jsonl",".json" } |
      Sort-Object LastWriteTimeUtc -Descending |
      Select-Object -First ($Limit * 2) |
      ForEach-Object { AddFile $_.FullName "codex" }
  }
}

$out = $sessions |
  Sort-Object mtime -Descending |
  Select-Object -First $Limit

@{
  ok = $true
  scope = $Scope
  folder = $Folder
  count = @($out).Count
  sessions = @($out)
} | ConvertTo-Json -Depth 6 -Compress
