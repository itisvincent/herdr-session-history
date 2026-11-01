# Session history (Herdr mod)

Orca-style **Agent Session History** for [Herdr](https://herdr.dev): a **Sessions** tab in the window's right panel (next to Files and Changes) that lists Pi / Claude / Codex sessions from disk, filters by the active space, and resumes one into a real space/tab — plus **Reveal in Explorer** and **Delete** (with confirm).

```text
Tell your agent:
Read ~/.config/herdr-app/AGENTS.md, then add this mod and its space-tabs panel button from one repo: https://github.com/itisvincent/herdr-session-history
Point the tab bar at mods/space-tabs and add a "sessions" child to the panel-body stack (RECIPE.md shows the exact wiring).
```

## What you get

- **Files · Changes · Sessions** tabs in the tab bar (bundled `space-tabs` clone; shipped mods untouched)
- Newest-first session list with one-line previews, per-agent chips (Pi / Claude / Codex), **This folder / All** scope, and an instant text filter
- **Resume**: exact-folder match opens a tab in that space; otherwise `space.new` — a real space, tab, and running agent in the sidebar
- **Reveal** selects the transcript file in Explorer (Windows) or Finder (macOS), or opens its folder (Linux); **Delete** arms first ("Delete?"), then removes it and rescans; **Copy cmd** copies the resume command

## Requirements

- Herdr app (desktop)
- Windows (`scan.ps1`), macOS or Linux (`scan.sh`)
- On Linux, `xdg-open` for Reveal and `wl-copy` (Wayland) or `xclip` (X11) for Copy cmd
- `pi` / `claude` / `codex` on `PATH` for Resume

See [RECIPE.md](RECIPE.md) for the full rebuild brief and layout wiring.

## License

MIT