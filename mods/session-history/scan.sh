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

# ---- Generic catalog (Orca-style: every CLI's transcript store we know) -----
# Documented paths are exact; the rest are best-effort roots — empty stores
# contribute nothing. Shapes differ per CLI, so id/cwd/preview use common
# field names, falling back to the file name.
import glob
CATALOG = [
    # (agent, [roots], id_fields, cwd_fields, preview_fields, argv_builder)
    ("gemini", ["~/.gemini/tmp"], ["sessionId", "id"], [], ["title"], lambda sid, cwd, p: ["gemini"]),
    ("cursor", ["~/.cursor/chats"], ["id", "sessionId"], ["cwd"], ["title", "firstPrompt"], lambda sid, cwd, p: ["cursor-agent", "--resume", sid]),
    ("droid", ["~/.factory/sessions"], ["id", "sessionId"], ["cwd", "workingDirectory"], ["title"], lambda sid, cwd, p: ["droid", "--resume", sid]),
    ("muse", ["~/.local/share/muse/sessions"], ["id", "sessionId"], ["cwd"], ["title", "firstPrompt"], lambda sid, cwd, p: ["muse", "resume", sid]),
    ("opencode", ["~/.local/share/opencode/storage/session"], ["id"], ["directory", "cwd"], ["title"], lambda sid, cwd, p: ["opencode", "--session", sid]),
    ("qoder", ["~/.qoder/projects"], ["id", "sessionId"], ["cwd"], ["title"], lambda sid, cwd, p: ["qoder"]),
    ("codebuddy", ["~/.codebuddy/projects"], ["id", "sessionId"], ["cwd"], ["title"], lambda sid, cwd, p: ["codebuddy"]),
    ("kimi", ["~/.kimi/sessions"], ["id", "sessionId"], ["cwd"], ["title"], lambda sid, cwd, p: ["kimi"]),
    ("kiro", ["~/.kiro/sessions"], ["id", "sessionId"], ["cwd"], ["title"], lambda sid, cwd, p: ["kiro"]),
    ("copilot", ["~/.copilot/sessions", "~/.copilot/cli/sessions"], ["id", "sessionId"], ["cwd"], ["title"], lambda sid, cwd, p: ["copilot"]),
    ("grok", ["~/.grok/sessions"], ["id", "sessionId"], ["cwd"], ["title"], lambda sid, cwd, p: ["grok"]),
    ("omp", ["~/.omp/sessions"], ["id", "sessionId"], ["cwd"], ["title"], lambda sid, cwd, p: ["omp"]),
    ("devin", ["~/.devin/sessions"], ["id", "sessionId"], ["cwd"], ["title"], lambda sid, cwd, p: ["devin"]),
    ("openclaw", ["~/.openclaw/sessions"], ["id", "sessionId"], ["cwd"], ["title"], lambda sid, cwd, p: ["openclaw"]),
    ("antigravity", ["~/.antigravity/sessions", "~/.gemini/antigravity"], ["id"], ["cwd"], ["title"], lambda sid, cwd, p: ["antigravity"]),
    ("prime", ["~/.prime/sessions"], ["id"], ["cwd"], ["title"], lambda sid, cwd, p: ["prime-agent"]),
    ("zcode", ["~/.zcode/projects"], ["id", "sessionId"], ["cwd"], ["title"], lambda sid, cwd, p: ["zcode"]),
    ("hermes", ["~/.hermes/sessions"], ["id"], ["cwd"], ["title"], lambda sid, cwd, p: ["hermes"]),
    ("cline", ["~/.cline/sessions", "~/.cline/projects"], ["id", "sessionId"], ["cwd"], ["title", "firstPrompt"], lambda sid, cwd, p: ["cline"]), 
    ("rovo", ["~/.rovo/sessions"], ["id", "sessionId"], ["cwd"], ["title"], lambda sid, cwd, p: ["rovo"]),
    ("jcode", ["~/.jcode/sessions", "~/.jcode/projects"], ["id", "sessionId"], ["cwd"], ["title"], lambda sid, cwd, p: ["jcode"]),
]

def generic_pick(o, fields):
    for f in fields:
        if isinstance(o, dict) and o.get(f):
            return str(o[f])
    return None

for agent, roots, id_fields, cwd_fields, preview_fields, argvb in CATALOG:
    files = []
    for root in roots:
        root = os.path.expanduser(root)
        if not os.path.isdir(root):
            continue
        for dirpath, _dirs, fnames in os.walk(root):
            for fname in fnames:
                if fname.endswith((".json", ".jsonl")):
                    files.append(os.path.join(dirpath, fname))
    files.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    for path in files[: limit * 2]:
        try:
            st = os.stat(path)
        except OSError:
            continue
        records = []
        try:
            with open(path, encoding="utf-8", errors="replace") as f:
                head = f.read(8192)
            for line in head.splitlines():
                line = line.strip()
                if not line: continue
                try: records.append(json.loads(line))
                except Exception: records.append(None)
                if len(records) >= 10: break
            if not records or all(r is None for r in records):
                with open(path, encoding="utf-8", errors="replace") as f:
                    records = [json.loads(f.read(8192))]
        except Exception:
            continue
        sid = cwd = preview = None
        for o in records + [{}]:
            if sid and cwd and preview: break
            if not sid: sid = generic_pick(o, id_fields)
            if not cwd: cwd = generic_pick(o, cwd_fields)
            if not preview: preview = generic_pick(o, preview_fields)
        if not sid:
            sid = os.path.splitext(os.path.basename(path))[0]
        preview = clean(preview)
        try:
            st = os.stat(path)
            add(agent, sid, path, cwd, preview, st.st_mtime * 1000, st.st_size, argvb(sid, cwd, path))
        except OSError:
            continue

out.sort(key=lambda s: s["mtime"], reverse=True)
print(json.dumps({"ok": True, "count": len(out[:limit]), "sessions": out[:limit]}))
PYEOF