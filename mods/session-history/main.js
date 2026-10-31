// Session history panel. Minimal paint first, then full UI once the slot shows.

import { View, div, svg, image } from "gpui-kit";
import { v_flex, h_flex, InputState, Input } from "gpui-base";
import {
  spaces, panes, run, theme, shared, setShared, exec, home, appHome, openOverlay, props, window, knownAgents,
} from "herdr";

const SCOPES = [
  { id: "folder", label: "This folder" },
  { id: "spaces", label: "Spaces" },
  { id: "all", label: "All" },
];
// Catalog mirrors Orca's Agent Session History: every CLI whose transcript
// store we can read gets scanned; empty stores simply contribute no rows.
const AGENTS = [
  { id: "pi", label: "Pi" },
  { id: "claude", label: "Claude" },
  { id: "codex", label: "Codex" },
  { id: "opencode", label: "OpenCode" },
  { id: "gemini", label: "Gemini" },
  { id: "cursor", label: "Cursor" },
  { id: "droid", label: "Droid" },
  { id: "muse", label: "Muse" },
  { id: "omp", label: "OMP" },
  { id: "prime", label: "Prime Agent" },
  { id: "copilot", label: "GitHub Copilot" },
  { id: "cline", label: "Cline" },
  { id: "grok", label: "Grok" },
  { id: "devin", label: "Devin" },
  { id: "openclaw", label: "OpenClaw" },
  { id: "rovo", label: "Rovo Dev" },
  { id: "kimi", label: "Kimi" },
  { id: "kiro", label: "Kiro" },
  { id: "codebuddy", label: "CodeBuddy" },
  { id: "jcode", label: "Jcode" },
  { id: "qoder", label: "Qoder" },
  { id: "zcode", label: "ZCode" },
  { id: "hermes", label: "Hermes" },
];

const scopeOf = () => SCOPES.find((s) => s.id === shared("session-history.scope")) ?? SCOPES[0];
const agentsOf = () => {
  const raw = shared("session-history.agents");
  const list = Array.isArray(raw) && raw.length ? raw : AGENTS.map((a) => a.id);
  return AGENTS.filter((a) => list.includes(a.id));
};

function age(ms) {
  if (!ms) return "";
  const d = Date.now() - ms;
  const m = Math.floor(d / 60000);
  if (m < 1) return "now";
  if (m < 60) return `${m}m`;
  const h = Math.floor(m / 60);
  if (h < 24) return `${h}h`;
  const days = Math.floor(h / 24);
  return days < 30 ? `${days}d` : `${Math.floor(days / 30)}mo`;
}

function activeFolder() {
  const s = spaces().find((x) => x.active);
  return s?.folder || null;
}

export default class SessionHistory extends View {
  init(_props, cx) {
    this.input = InputState.new({ placeholder: "Type to filter…" });
    this.filter = "";
    this.input.on("change", (_e, cx) => { this.filter = this.input.value(); cx.notify(); });
    this.sessions = [];
    this.error = null;
    this.loading = false;
    this.token = 0;
    this.expanded = null;
    this.booted = false;
    this.icons = {};
    cx.spawn(async (cx) => {
      // Orca-style logos: the app's program table carries per-agent icons.
      try {
        const known = await knownAgents();
        this.icons = Object.fromEntries((known || []).map((p) => [p.key, p]));
        cx.notify();
      } catch {}
      await this.refresh(cx);
      this.booted = true;
      cx.notify();
      for (;;) {
        await cx.timer.wait(15000);
        await this.refresh(cx);
      }
    });
  }

  async refresh(cx) {
    const token = ++this.token;
    this.loading = true;
    this.error = null;
    cx.notify();
    const platform = window()?.platform;
    try {
      let r;
      if (platform === "windows") {
        r = await exec("powershell", [
          "-NoProfile",
          "-ExecutionPolicy", "Bypass",
          "-File", `${appHome()}/mods/session-history/scan.ps1`,
          "-Limit", "120",
        ]);
      } else {
        r = await exec("bash", [
          `${appHome()}/mods/session-history/scan.sh`,
          "--limit", "120",
        ]);
      }
      if (token !== this.token) return;
      if (r.code !== 0) {
        const raw = (r.stderr || r.stdout || `scan exited ${r.code}`).trim().slice(0, 240);
        this.error = /python3|scan\.sh/.test(raw)
          ? "Scanner needs python3 (macOS: xcode-select --install)"
          : raw;
        this.sessions = [];
      } else {
        const data = JSON.parse((r.stdout || "").trim() || "{}" );
        this.sessions = Array.isArray(data.sessions) ? data.sessions : [];
        this.error = null;
      }
    } catch (e) {
      if (token !== this.token) return;
      this.error = String(e?.message || e).slice(0, 240);
      this.sessions = [];
    }
    this.loading = false;
    cx.notify();
  }

  normPath(p) {
    // Normalize separators and case so Windows paths compare consistently.
    return String(p || "").replace(/\\/g, "/").replace(/\/+$/, "").toLowerCase();
  }

  // Exact-folder space lookup for labeling: a session inside a space's root
  // shows the space's name, so "job-ai repo root of herdr-app space" reads
  // "herdr-app" instead of a colliding folder name.
  spaceLabelFor(cwd) {
    const n = this.normPath(cwd);
    if (!n) return null;
    // Name the space whose live terminal is in this cwd (or whose root matches).
    const tabIds = new Set();
    let byPane = null;
    for (const p of panes()) {
      if (p.terminal && p.cwd && this.normPath(p.cwd) === n) { byPane = p.tab; break; }
    }
    if (byPane) {
      const s = spaces().find((sp) => (sp.tabs || []).some((t) => t.id === byPane));
      if (s) return s.name;
    }
    const space = spaces().find((sp) => this.normPath(sp.folder) === n);
    return space ? space.name : null;
  }

  // Folders the active space really works in: every live terminal's cwd in
  // its tabs. The space's recorded root folder is NOT included on purpose —
  // it's often a stale parent (space created in repo A, terminal cd'd to B),
  // which would pull unrelated sessions into one panel.
  spaceFolders() {
    const out = new Set();
    const space = spaces().find((s) => s.active);
    if (!space) return out;
    const add = (p) => { const n = this.normPath(p); if (n) out.add(n); };
    const tabIds = new Set((space.tabs || []).map((t) => t.id));
    for (const p of panes()) {
      if (p.terminal && tabIds.has(p.tab)) add(p.cwd);
    }
    return out;
  }

  inSpace(cwd, folders) {
    const n = this.normPath(cwd);
    if (!n || folders.size === 0) return false;
    if (folders.has(n)) return true;
    for (const f of folders) {
      if (n.startsWith(f + "/")) return true;
    }
    return false;
  }

  // Which space a session belongs to: the space with a live terminal in this
  // cwd, else the space whose root folder matches. Null = no space claims it.
  assignSpace(s) {
    const n = this.normPath(s.cwd);
    if (!n) return null;
    const pane = panes().find((p) => p.terminal && p.cwd && this.normPath(p.cwd) === n);
    if (pane) {
      const s2 = spaces().find((sp) => (sp.tabs || []).some((t) => t.id === pane.tab));
      if (s2) return s2;
    }
    return spaces().find((sp) => this.normPath(sp.folder) === n) || null;
  }

  filtered() {
    const q = (this.filter || "").trim().toLowerCase();
    const scope = scopeOf();
    const allow = new Set(agentsOf().map((a) => a.id));
    const folders = scope.id === "folder" ? this.spaceFolders() : null;
    return this.sessions.filter((s) => {
      if (allow.size && !allow.has(s.agent)) return false;
      if (folders && !this.inSpace(s.cwd, folders)) return false;
      if (scope.id === "spaces" && !this.assignSpace(s)) return false;
      if (!q) return true;
      const hay = `${s.agent} ${s.folder || ""} ${s.cwd || ""} ${s.preview || ""} ${s.id || ""}`.toLowerCase();
      return hay.includes(q);
    });
  }

  spaceForFolder(folder) {
    // Exact folder only: a prefix match would drop C:\Users\Vincent\Downloads
    // into a session-less space whose folder is C:\Users\Vincent.
    const want = this.normPath(folder);
    if (!want) return null;
    return spaces().find((s) => this.normPath(s.folder) === want) || null;
  }

  // Open the session as a real Herdr tab (and a space when its folder is new),
  // same path the + menu uses: argv starts the agent in that folder.
  resume(s) {
    if (!s?.argv?.length) return;
    const folder = s.cwd || activeFolder() || home();
    const name = s.folder || s.agent || "session";
    const argv = s.argv;
    // Exact-match space else a new one, so Spaces shows where it really lives.
    const existing = this.spaceForFolder(folder);
    if (existing) {
      run("tab.new", { name, space: existing.id, folder, argv });
      if (!existing.active) run("space.select", { id: existing.id });
      return;
    }
    run("space.new", { name, folder, argv });
  }

  toggleAgent(id) {
    const cur = agentsOf().map((a) => a.id);
    const next = cur.includes(id) ? cur.filter((x) => x !== id) : [...cur, id];
    setShared("session-history.agents", next.length ? next : AGENTS.map((a) => a.id));
  }

  psQuote(s) {
    return String(s).replace(/'/g, "''");
  }

  // Orca-style: open Explorer with the transcript selected.
  reveal(s) {
    exec("powershell", [
      "-NoProfile",
      "-Command",
      `Start-Process explorer.exe -ArgumentList '/select,"${this.psQuote(s.path)}"'`,
    ]).catch(() => {});
  }

  // Two-step: first click arms, second click deletes the transcript file for real.
  delete(s, cx) {
    if (this.confirmDelete !== s.path) {
      this.confirmDelete = s.path;
      cx.notify();
      return;
    }
    this.confirmDelete = null;
    this.expanded = null;
    cx.notify();
    exec("powershell", [
      "-NoProfile",
      "-Command",
      `Remove-Item -LiteralPath '${this.psQuote(s.path)}' -Force -ErrorAction SilentlyContinue`,
    ])
      .then(() => this.refresh(cx))
      .catch(() => this.refresh(cx));
  }

  chip(t, id, label, on, onClick) {
    return div()
      .id(id)
      .px(8)
      .h(22)
      .rounded(6)
      .text_size(10.5)
      .font_medium()
      .flex()
      .items_center()
      .cursor_pointer()
      .when(on, (el) => el.bg(t.selected).text_color(t.foreground))
      .when(!on, (el) => el.bg(t.raised).text_color(t.dim).hover((el) => el.bg(t.hover).text_color(t.foreground)))
      .on_click((_e, cx) => {
        cx.stop_propagation();
        onClick(cx);
      })
      .child(label);
  }

  agentsMenu(t) {
    const agents = agentsOf();
    return v_flex()
      .w_full()
      .p(5)
      .text_size(12.8)
      .child(div().px(8).pt(4).pb(6).text_size(11).text_color(t.dim).child("Agents to scan"))
      .children(AGENTS.map((a) => {
        const on = agents.some((x) => x.id === a.id);
        const prog = (this.icons || {})[a.id];
        const logo = prog?.icon
          ? (prog.tint ? svg(prog.icon).size(14).flex_none().text_color(t.foreground)
                       : image(prog.icon).w(16).h(16).flex_none())
          : div().w(14).h(14).flex_none().rounded(4).bg(t.raised).text_color(t.foreground).text_size(9).font_bold().flex().items_center().justify_center().child(a.label[0]);
        return h_flex()
          .id(`menu-agent-${a.id}`)
          .h(31)
          .px(8)
          .gap(9)
          .rounded(7)
          .items_center()
          .text_color(t.foreground)
          .hover((el) => el.bg(t.hover))
          .on_click((_e, cx) => {
            cx.stop_propagation();
            this.toggleAgent(a.id);
            cx.notify();
          })
          .child(logo)
          .child(div().flex_1().child(a.label))
          .when(on, (el) => el.child(svg("mods/workspace-chrome/check.svg").size(14).flex_none().text_color(t.foreground)));
      }));
  }

  render(cx) {
    const t = theme();
    if (props()?.agentsMenu) return this.agentsMenu(t);
    const scope = scopeOf();
    const agents = agentsOf();
    const list = this.filtered();

    const row = (s, i) => {
      const open = this.expanded === s.path;
      return v_flex()
        .id(`sess-${s.agent}-${i}`)
        .flex_none()
        .px(9)
        .py(7)
        .gap(4)
        .rounded(8)
        .cursor_pointer()
        .when(open, (el) => el.bg(t.raised))
        .when(!open, (el) => el.hover((el) => el.bg(t.hover)))
        .on_click((_e, c) => {
          this.expanded = open ? null : s.path;
          c.notify();
        })
        .child(
          h_flex()
            .items_center()
            .gap(8)
            .child(
              h_flex()
                .w(44)
                .flex_none()
                .h(16)
                .rounded(4)
                .items_center()
                .justify_center()
                .when(s.agent === "pi", (el) => el.bg(t.working + "22").text_color(t.working))
                .when(s.agent === "claude", (el) => el.bg(t.done + "22").text_color(t.done))
                .when(s.agent === "codex", (el) => el.bg((t.ansi4 || t.accent) + "22").text_color(t.ansi4 || t.accent))
                .child(div().text_size(9.5).font_bold().child(String(s.agent || "?").toUpperCase())),
            )
            .child(div().flex_1().min_w(0).truncate().text_size(12).text_color(t.foreground).child(this.spaceLabelFor(s.cwd) || s.folder || s.cwd || s.id))
            .child(div().text_size(10.5).text_color(t.dim).child(age(s.mtime))),
        )
        .when(Boolean(s.preview), (el) =>
          el.child(div().pl(44).text_size(11).text_color(t.muted).truncate().child(s.preview)),
        )
        .when(open, (el) =>
          el
            .child(div().pl(44).pt(2).text_size(10.5).text_color(t.dim).truncate().child(s.cwd || "(no folder recorded)"))
            .child(
              h_flex()
                .pl(44)
                .gap(6)
                .pt(3)
                .child(
                  div()
                    .id(`resume-${s.agent}-${i}`)
                    .px(10)
                    .h(24)
                    .rounded(6)
                    .bg(t.accent)
                    .text_color(t.accent_foreground || t.background)
                    .text_size(11)
                    .font_semibold()
                    .flex()
                    .items_center()
                    .cursor_pointer()
                    .on_click((_e, c) => {
                      c.stop_propagation();
                      this.resume(s);
                    })
                    .child("Resume"),
                )
                .child(
                  div()
                    .id(`copy-${s.agent}-${i}`)
                    .px(8)
                    .h(24)
                    .rounded(6)
                    .border_1()
                    .border_color(t.border)
                    .text_size(10.5)
                    .text_color(t.dim)
                    .flex()
                    .items_center()
                    .hover((el) => el.bg(t.hover).text_color(t.foreground))
                    .tooltip((s.argv || []).join(" "))
                    .on_click((_e, c) => {
                      c.stop_propagation();
                      const cmd = (s.argv || []).map((a) => String(a).replace(/'/g, "''")).join(" ");
                      exec("powershell", ["-NoProfile", "-Command", `Set-Clipboard -Value '${cmd}'`]).catch(() => {});
                    })
                    .child("Copy cmd"),
                )
                .child(
                  div()
                    .id(`reveal-${s.agent}-${i}`)
                    .px(8)
                    .h(24)
                    .rounded(6)
                    .border_1()
                    .border_color(t.border)
                    .text_size(10.5)
                    .text_color(t.dim)
                    .flex()
                    .items_center()
                    .hover((el) => el.bg(t.hover).text_color(t.foreground))
                    .tooltip("Show this transcript in Explorer")
                    .on_click((_e, c) => {
                      c.stop_propagation();
                      this.reveal(s);
                    })
                    .child("Reveal"),
                )
                .when(this.confirmDelete === s.path, (el) =>
                  el
                    .child(
                      div()
                        .id(`delete-yes-${s.agent}-${i}`)
                        .px(8)
                        .h(24)
                        .rounded(6)
                        .bg(t.blocked)
                        .text_color(t.background)
                        .text_size(10.5)
                        .font_semibold()
                        .flex()
                        .items_center()
                        .cursor_pointer()
                        .on_click((_e, c) => {
                          c.stop_propagation();
                          this.delete(s, c);
                        })
                        .child("Delete?"),
                    )
                    .child(
                      div()
                        .id(`delete-no-${s.agent}-${i}`)
                        .px(6)
                        .h(24)
                        .text_size(10.5)
                        .text_color(t.dim)
                        .hover((el) => el.text_color(t.foreground))
                        .on_click((_e, c) => {
                          c.stop_propagation();
                          this.confirmDelete = null;
                          c.notify();
                        })
                        .child("Keep it"),
                    ),
                )
                .when(this.confirmDelete !== s.path, (el) =>
                  el.child(
                    div()
                      .id(`delete-${s.agent}-${i}`)
                      .px(8)
                      .h(24)
                      .rounded(6)
                      .border_1()
                      .border_color(t.border)
                      .text_size(10.5)
                      .text_color(t.blocked)
                      .flex()
                      .items_center()
                      .hover((el) => el.bg(t.hover))
                      .tooltip("Permanently delete this transcript")
                      .on_click((_e, c) => {
                        c.stop_propagation();
                        this.delete(s, c);
                      })
                      .child("Delete"),
                  ),
                ),
            ),
        );
    };

    return v_flex()
      .id("session-history")
      .size_full()
      .min_h(0)
      .rounded(10)
      .overflow_hidden()
      .bg(t.background)
      .border_1()
      .border_color(t.border)
      .text_size(13)
      .text_color(t.foreground)
      .child(
        h_flex()
          .h(42)
          .flex_none()
          .px(14)
          .gap(8)
          .items_center()
          .border_b(1)
          .border_color(t.border)
          .child(div().font_semibold().child("Sessions"))
          .child(div().flex_1())
          .child(
            div()
              .id("sh-refresh")
              .text_size(12)
              .text_color(t.dim)
              .hover((el) => el.text_color(t.foreground))
              .on_click((_e, c) => this.refresh(c))
              .child(this.loading ? "…" : "↻"),
          )
          .child(
            div()
              .id("sh-collapse")
              .text_size(13)
              .text_color(t.dim)
              .hover((el) => el.text_color(t.foreground))
              .tooltip("Hide panel (Sessions / ctrl-alt-s brings it back)")
              .on_click(() => run("layout.hide", { id: "panel" }))
              .child("›"),
          ),
      )
      .child(
        h_flex()
          .px(12)
          .py(8)
          .gap(4)
          .flex_none()
          .children(SCOPES.map((s) => this.chip(t, `scope-${s.id}`, s.label, scope.id === s.id, (c) => {
            setShared("session-history.scope", s.id);
            cx.notify();
          })))
          .child(div().flex_1())
          .child(
            // Agent filter as a dropdown: keeps the header to one row.
            h_flex()
              .id("sh-agents-menu")
              .px(8)
              .h(22)
              .gap(5)
              .rounded(6)
              .text_size(10.5)
              .font_medium()
              .flex()
              .items_center()
              .cursor_pointer()
              .bg(t.raised)
              .text_color(t.foreground)
              .hover((el) => el.bg(t.hover))
              .on_click((_e, c) => {
                c.stop_propagation();
                openOverlay({ mod: "session-history", kind: "popup", width: 200, height: AGENTS.length * 32 + 26, props: { agentsMenu: true } });
              })
              .child(svg("mods/workspace-chrome/layers.svg").size(12).text_color(t.dim))
              .child(`Agents (${agents.length})`),
          ),
      )
      .child(
        div()
          .px(12)
          .pb(8)
          .flex_none()
          .child(
            Input.new(this.input)
              .h(28)
              .px(10)
              .rounded(7)
              .border_1()
              .border_color(t.input)
              .bg(t.background)
              .text_size(12)
              .text_color(t.foreground),
          ),
      )
      .when(Boolean(this.error), (el) =>
        el.child(div().px(12).pb(8).text_size(11).text_color(t.blocked).child(this.error)),
      )
      .when(this.loading && list.length === 0, (el) =>
        el.child(div().px(12).text_size(12).text_color(t.dim).child("Scanning sessions…")),
      )
      .when(!this.loading && list.length === 0 && !this.error, (el) =>
        el.child(
          div()
            .px(12)
            .text_size(12)
            .text_color(t.dim)
            .child(
              scope.id === "folder"
                ? "No sessions for this space’s folder. Switch to All, or start an agent here."
                : "No sessions found under ~/.pi, Claude projects, or ~/.codex.",
            ),
        ),
      )
      .child(
        v_flex()
          .id("sh-list")
          .flex_1()
          .min_h(0)
          .px(6)
          .pb(6)
          .gap(1)
          .overflow_y_scrollbar()
          .children(
            scope.id === "spaces"
              ? spaces().flatMap((sp) => {
                  const members = list.filter((s) => {
                    const owner = this.assignSpace(s);
                    return owner && owner.id === sp.id;
                  });
                  if (!members.length) return [];
                  return [
                    h_flex()
                      .id(`sh-group-${sp.id}`)
                      .flex_none()
                      .px(6)
                      .pt(8)
                      .pb(3)
                      .gap(6)
                      .items_center()
                      .child(div().text_size(10.5).font_semibold().text_color(t.dim).child(sp.name))
                      .child(div().flex_1().h(1).bg(t.border))
                      .child(div().text_size(10).text_color(t.dim).child(String(members.length))),
                    ...members.map((s, i) => row(s, i)),
                  ];
                })
              : list.map((s, i) => row(s, i)),
          ),
      );
  }
}
