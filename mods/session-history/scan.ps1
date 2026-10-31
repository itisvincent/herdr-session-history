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

function Add-ExtraAgent([string]$agent, [string[]]$roots, [string[]]$cwdFields, [string[]]$titleFields, [scriptblock]$argvOf) {
  foreach ($root in $roots) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    $files = Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue |
      Where-Object { $_.Extension -in ".json",".jsonl" } |
      Sort-Object LastWriteTimeUtc -Descending |
      Select-Object -First ($Limit * 2)
    foreach ($f in $files) {
      try { $o = Get-Content $f.FullName -Raw | ConvertFrom-Json -ErrorAction Stop } catch { continue }
      if (-not $o) { continue }
      $sid = $null
      foreach ($fld in @("id","sessionId","session_id")) {
        if ($o.$fld) { $sid = [string]$o.$fld; break }
      }
      if (-not $sid) { $sid = [IO.Path]::GetFileNameWithoutExtension($f.Name) }
      $cwd = ""
      foreach ($fld in $cwdFields) {
        if ($o.$fld) { $cwd = [string]$o.$fld; break }
      }
      $title = ""
      foreach ($fld in $titleFields) {
        if ($o.$fld) { $title = [string]$o.$fld; break }
      }
      $argv = & $argvOf $sid
      $sessions.Add([ordered]@{
        agent = $agent; id = $sid; path = $f.FullName; cwd = $cwd
        folder = RelLabel $cwd; preview = $title
        mtime = [int64]([DateTimeOffset]$f.LastWriteTimeUtc).ToUnixTimeMilliseconds()
        size = [int64]$f.Length; argv = $argv
      }) | Out-Null
    }
  }
}

function Add-ExtraAgent([string]$agent, [string[]]$roots, [string[]]$cwdFields, [string[]]$titleFields, [scriptblock]$argvOf) {
  foreach ($root in $roots) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    $files = Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue |
      Where-Object { $_.Extension -in ".json",".jsonl" } |
      Sort-Object LastWriteTimeUtc -Descending |
      Select-Object -First ($Limit * 2)
    foreach ($f in $files) {
      try { $raw = Get-Content $f.FullName -Raw -ErrorAction Stop; $o = $raw | ConvertFrom-Json -ErrorAction Stop } catch {}
      if (-not $o) { continue }
      $sid = $null
      foreach ($fld in @("id","sessionId","session_id")) {
        if ($o.$fld) { $sid = [string]$o.$fld; break }
      }
      if (-not $sid) { $sid = [IO.Path]::GetFileNameWithoutExtension($f.Name) }
      $cwd = ""
      foreach ($fld in $cwdFields) {
        if ($o.$fld) { $cwd = [string]$o.$fld; break }
      }
      $title = ""
      foreach ($fld in $titleFields) {
        if ($o.$fld) { $title = [string]$o.$fld; break }
      }
      $argv = & $argvOf $sid
      $sessions.Add([ordered]@{
        agent = $agent; id = $sid; path = $f.FullName; cwd = $cwd
        folder = RelLabel $cwd; preview = $title
        mtime = [int64]([DateTimeOffset]$f.LastWriteTimeUtc).ToUnixTimeMilliseconds()
        size = [int64]$f.Length; argv = $argv
      }) | Out-Null
    }
  }
}

# OpenCode (best-effort: storage shape varies by version)
Add-ExtraAgent "opencode" @("$env:USERPROFILE\.local\share\opencode\storage\session") @("directory","cwd") @("title") { param($sid) @("opencode","--session",$sid) }

# Gemini (session json under tmp; resume is in-TUI /resume)
Add-ExtraAgent "gemini" @("$env:USERPROFILE\.gemini\tmp") @("cwd") @("title") { param($sid) @("gemini") }

# Cursor agent CLI chats
Add-ExtraAgent "cursor" @("$env:USERPROFILE\.cursor\chats") @("cwd") @("title","firstPrompt") { param($sid) @("cursor-agent","--resume",$sid) }

# Droid (Factory) home-scope sessions
Add-ExtraAgent "droid" @("$env:USERPROFILE\.factory\sessions") @("cwd","workingDirectory") @("title") { param($sid) @("droid","--resume",$sid) }

# Muse Code
Add-ExtraAgent "muse" @("$env:USERPROFILE\.local\share\muse\sessions") @("cwd") @("title","firstPrompt") { param($sid) @("muse","resume",$sid) }

# Qoder / CodeBuddy / Kimi / Kiro / Copilot / Grok / OMP / Devin / OpenClaw / Rovo / Cline / Jcode / Hermes / Antigravity / Prime / ZCode (best-effort)
Add-ExtraAgent "qoder" @("$env:USERPROFILE\.qoder\projects") @("cwd") @("title") { param($sid) @("qoder") }
Add-ExtraAgent "codebuddy" @("$env:USERPROFILE\.codebuddy\projects") @("cwd") @("title") { param($sid) @("codebuddy") }
Add-ExtraAgent "kimi" @("$env:USERPROFILE\.kimi\sessions") @("cwd") @("title") { param($sid) @("kimi") }
Add-ExtraAgent "kiro" @("$env:USERPROFILE\.kiro\sessions") @("cwd") @("title") { param($sid) @("kiro") }
Add-ExtraAgent "copilot" @("$env:USERPROFILE\.copilot\sessions","$env:USERPROFILE\.copilot\cli\sessions") @("cwd") @("title") { param($sid) @("copilot") }
Add-ExtraAgent "grok" @("$env:USERPROFILE\.grok\sessions") @("cwd") @("title") { param($sid) @("grok") }
Add-ExtraAgent "omp" @("$env:USERPROFILE\.omp\sessions") @("cwd") @("title") { param($sid) @("omp") }
Add-ExtraAgent "devin" @("$env:USERPROFILE\.devin\sessions") @("cwd") @("title") { param($sid) @("devin") }
Add-ExtraAgent "openclaw" @("$env:USERPROFILE\.openclaw\sessions") @("cwd") @("title") { param($sid) @("openclaw") }
Add-ExtraAgent "rovo" @("$env:USERPROFILE\.rovo\sessions") @("cwd") @("title") { param($sid) @("rovo") }
Add-ExtraAgent "cline" @("$env:USERPROFILE\.cline\sessions","$env:USERPROFILE\.cline\projects") @("cwd") @("title","firstPrompt") { param($sid) @("cline") }
Add-ExtraAgent "jcode" @("$env:USERPROFILE\.jcode\sessions","$env:USERPROFILE\.jcode\projects") @("cwd") @("title") { param($sid) @("jcode") }
Add-ExtraAgent "hermes" @("$env:USERPROFILE\.hermes\sessions") @("cwd") @("title") { param($sid) @("hermes") }
Add-ExtraAgent "antigravity" @("$env:USERPROFILE\.antigravity\sessions","$env:USERPROFILE\.gemini\antigravity") @("cwd") @("title") { param($sid) @("antigravity") }
Add-ExtraAgent "prime" @("$env:USERPROFILE\.prime\sessions") @("cwd") @("title") { param($sid) @("prime-agent") }
Add-ExtraAgent "zcode" @("$env:USERPROFILE\.zcode\projects") @("cwd") @("title") { param($sid) @("zcode") }

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
