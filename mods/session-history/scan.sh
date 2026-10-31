#!/usr/bin/env bash
# Lists recent agent sessions as one JSON object: {"ok":true,"sessions":[...]}.
# Port of scan.ps1 for macOS/Linux. Needs python3 (ships with macOS 12.3+ Xcode tools).
# Usage: scan.sh [--limit N]  (scope/agent filtering happens client-side in the mod)

set -u
LIMIT=80
while [ $# -gt 0 ]; do
  case "$1" in
    --limit) LIMIT="$2"; shift 2 ;;
    --scope|--folder|--agents) shift; shift ;;   # kept for CLI compat; filtering is client-side
    *) shift ;;
  esac
done

if ! command -v python3 >/dev/null 2>&1; then
  echo '{"ok":false,"error":"scan.sh needs python3 (macOS: xcode-select --install)"}' >&2
  exit 3
fi

HOME_DIR="$HOME" LIMIT="$LIMIT" python3 - <<'PYEOF'
import os, sys, json, time

home = os.environ["HOME_DIR"]
limit = int(os.environ.get("LIMIT", "80"))
out = []

def add(agent, sid, path, cwd, preview, mtime, size, argv):
    folder = ""
    if cwd:
        folder = os.path.basename((cwd or "").rstrip("/\\")) or cwd
    out.append({
        "agent": agent, "id": sid, "path": path, "cwd": cwd or "",
        "folder": folder, "preview": preview or "",
        "mtime": int(mtime), "size": int(size), "argv": argv,
    })

def head_records(path, n=40):
    recs = []
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for i, line in enumerate(f):
                if i >= n: break
                line = line.strip()
                if not line: continue
                try: recs.append(json.loads(line))
                except Exception: continue
    except OSError:
        pass
    return recs

def clean(s, n=160):
    s = " ".join(str(s or "").split())
    return s[:n] if len(s) > n else s

# ---- Pi ------------------------------------------------------------------
pi_root = os.path.join(home, ".pi", "agent", "sessions")
pi_files = []
for dirpath, _dirs, files in os.walk(pi_root):
    for f in files:
        if f.endswith(".jsonl"):
            pi_files.append(os.path.join(dirpath, f))
pi_files.sort(key=lambda p: os.path.getmtime(p), reverse=True)
for path in pi_files[: limit * 2]:
    try:
        st = os.stat(path)
    except OSError:
        continue
    if st.st_size < 20: continue
    cwd = sid = None; preview = ""
    for o in head_records(path):
        if o.get("type") == "session":
            if o.get("cwd"): cwd = str(o["cwd"])
            if o.get("id"): sid = str(o["id"])
        if not preview and o.get("type") == "message":
            m = o.get("message") or {}
            if m.get("role") == "user":
                for c in (m.get("content") or []):
                    if isinstance(c, dict) and c.get("type") == "text" and c.get("text"):
                        preview = clean(c["text"]); break
        if cwd and sid and preview: break
    if not sid:
        base = os.path.splitext(os.path.basename(path))[0]
        if "_" in base: sid = base.rsplit("_", 1)[-1]
        else: sid = base
    add("pi", sid, path, cwd, preview, st.st_mtime * 1000, st.st_size, ["pi", "--session", path])

# ---- Claude (native + ReClaude junction layouts) ---------------------------
claude_roots = [
    os.path.join(home, ".claude", "projects"),
]
rec = os.path.join(home, ".rec", "claude", "accounts")
if os.path.isdir(rec):
    for acc in os.listdir(rec):
        p = os.path.join(rec, acc, "config", "projects")
        if os.path.isdir(p): claude_roots.append(p)

claude_files = []
for root in claude_roots:
    for dirpath, _dirs, files in os.walk(root):
        if os.sep + "subagents" + os.sep in dirpath: continue
        for f in files:
            if f.endswith(".jsonl"):
                claude_files.append(os.path.join(dirpath, f))
claude_files.sort(key=lambda p: os.path.getmtime(p), reverse=True)
for path in claude_files[: limit * 2]:
    try:
        st = os.stat(path)
    except OSError:
        continue
    if st.st_size < 20: continue
    cwd = sid = None; preview = ""
    for o in head_records(path):
        if not sid and o.get("sessionId"): sid = str(o["sessionId"])
        if not cwd and o.get("cwd"): cwd = str(o["cwd"])
        if not preview:
            m = o.get("message") if isinstance(o.get("message"), dict) else None
            if o.get("type") in ("human", "user") or (m and m.get("role") == "user"):
                text = None
                if m and m.get("content") is not None:
                    text = m["content"] if isinstance(m["content"], str) else None
                    if text is None:
                        for c in (m["content"] or []):
                            if isinstance(c, dict) and c.get("type") == "text" and c.get("text"):
                                text = c["text"]; break
                if text is None and isinstance(o.get("content"), str):
                    text = o["content"]
                if text:
                    preview = clean(text)
        if cwd and sid and preview: break
    if not sid:
        sid = os.path.splitext(os.path.basename(path))[0]
    add("claude", sid, path, cwd, preview, st.st_mtime * 1000, st.st_size, ["claude", "--resume", sid])

# ---- Codex -----------------------------------------------------------------
codex_root = os.path.join(home, ".codex", "sessions")
if os.path.isdir(codex_root):
    codex_files = []
    for dirpath, _dirs, files in os.walk(codex_root):
        for f in files:
            if f.endswith((".jsonl", ".json")):
                codex_files.append(os.path.join(dirpath, f))
    codex_files.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    for path in codex_files[: limit * 2]:
        try:
            st = os.stat(path)
        except OSError:
            continue
        cwd = sid = None; preview = ""
        for o in head_records(path):
            if o.get("type") == "session_meta" and isinstance(o.get("payload"), dict):
                if o["payload"].get("id"): sid = str(o["payload"]["id"])
                if o["payload"].get("cwd"): cwd = str(o["payload"]["cwd"])
            if not sid and o.get("session_id"): sid = str(o["session_id"])
            if not cwd and o.get("cwd"): cwd = str(o["cwd"])
            if not preview and isinstance(o.get("payload"), dict):
                pl = o["payload"]
                if pl.get("type") == "user_message" and pl.get("message"):
                    preview = clean(pl["message"])
            if cwd and sid and preview: break
        if not sid:
            sid = os.path.splitext(os.path.basename(path))[0]
        add("codex", sid, path, cwd, preview, st.st_mtime * 1000, st.st_size, ["codex", "resume", sid])

# ---- OpenCode (best-effort: version-dependent storage shape) ---------------
oc_root = os.path.join(home, ".local", "share", "opencode", "storage", "session")
if os.path.isdir(oc_root):
    oc_files = []
    for dirpath, _dirs, files in os.walk(oc_root):
        for f in files:
            if f.endswith(".json"):
                oc_files.append(os.path.join(dirpath, f))
    oc_files.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    for path in oc_files[: limit * 2]:
        try:
            st = os.stat(path)
        except OSError:
            continue
        try:
            with open(path, encoding="utf-8", errors="replace") as f:
                o = json.loads(f.read(4096))
        except Exception:
            continue
        sid = str(o.get("id") or os.path.splitext(os.path.basename(path))[0])
        cwd = str(o.get("directory") or o.get("cwd") or "")
        title = str(o.get("title") or "")
        add("opencode", sid, path, cwd, clean(title), st.st_mtime * 1000, st.st_size, ["opencode", "--session", sid])

out.sort(key=lambda s: s["mtime"], reverse=True)
print(json.dumps({"ok": True, "count": len(out[:limit]), "sessions": out[:limit]}))
PYEOF