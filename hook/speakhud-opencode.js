// Feed finished OpenCode turns to SpeakHUD, the same way Claude Code's Stop hook
// (~/.claude/read-summary.py) does: write a v1 spool file into the queue the
// SpeakHUD agent drains. Contract pinned by speak-hud.swift / SpoolTests.swift.
import { writeFileSync, renameSync, mkdirSync } from "node:fs"
import { execFileSync } from "node:child_process"
import os from "node:os"
import path from "node:path"

const SPOOL_VERSION = 1
const QUEUE = (() => {
  const o = process.env.SPEAKHUD_QUEUE_DIR
  if (o) return path.resolve(o.replace(/^~(?=$|\/)/, os.homedir()))
  return path.join(os.homedir(), ".local/state/speakhud/queue")
})()

// Which terminal this OpenCode runs in, so clicking the HUD's project pill goes back
// to it: read-summary.py's origin() fields, under the same `origin` key the agent
// reads. iTerm2 is found by session id, Terminal.app by tty, anything else by the
// outermost .app above us. Found once: an OpenCode process never changes terminal.
let origin
function terminalOrigin() {
  if (origin !== undefined) return origin
  const out = {}
  const term = process.env.TERM_PROGRAM
  if (term) out.term = term
  const m = /^(?:w\d+t\d+p\d+:)?([0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12})$/.exec(process.env.ITERM_SESSION_ID || "")
  if (m) out.session = m[1].toUpperCase()
  try {
    const ps = execFileSync("/bin/ps", ["-axo", "pid=,ppid=,tty=,comm="], { encoding: "utf8", timeout: 2000 })
    const table = new Map()
    for (const line of ps.split("\n")) {
      const [pid, ppid, tty, ...comm] = line.trim().split(/\s+/)
      if (/^\d+$/.test(pid) && /^\d+$/.test(ppid)) table.set(+pid, [+ppid, tty, comm.join(" ")])
    }
    const seen = new Set()
    for (let pid = process.pid; pid > 1 && table.has(pid) && !seen.has(pid); pid = table.get(pid)[0]) {
      seen.add(pid)
      const [, tty, comm] = table.get(pid)
      if (!out.tty && /^ttys\d+$/.test(tty)) out.tty = "/dev/" + tty
      if (/\.app\/Contents\/MacOS\//.test(comm)) out.app_pid = pid
    }
  } catch { /* no tty or app: the turn is still read */ }
  origin = out.session || out.tty || out.app_pid ? out : null
  return origin
}

export const SpeakHUD = async ({ client }) => {
  const spoken = new Set() // dedupe by assistant message id
  return {
    event: async ({ event }) => {
      if (event?.type !== "session.idle") return
      const id = event.properties?.sessionID
      if (!id) return
      // A subagent's session goes idle mid-run: only the top-level session's
      // turn is finished.
      try {
        const info = await client.session.get({ path: { id } })
        if ((info?.data ?? info)?.parentID) return
      } catch { return }
      let msgs
      try {
        const res = await client.session.messages({ path: { id } })
        msgs = res?.data ?? res
      } catch { return }
      if (!Array.isArray(msgs)) return
      let last
      for (const m of msgs) if (m?.info?.role === "assistant") last = m
      if (!last || spoken.has(last.info.id)) return
      spoken.add(last.info.id)
      const text = (last.parts || [])
        .filter((p) => p.type === "text" && !p.synthetic && !p.ignored)
        .map((p) => p.text)
        .join("")
        .trim()
      if (!text) return
      const cwd = last.info?.path?.cwd || ""
      const item = {
        v: SPOOL_VERSION,
        text,
        source: cwd ? path.basename(cwd) : "opencode",
        key: last.info.id,
        created: Date.now() / 1000,
      }
      if (cwd) item.cwd = cwd
      const where = terminalOrigin()
      if (where) item.origin = where
      // Sync so the write + atomic rename both finish before this handler
      // returns: `opencode run` exits immediately after a turn and would
      // otherwise kill an async rename mid-flight, stranding a .tmp.
      try {
        mkdirSync(QUEUE, { recursive: true })
        const stem = `${(BigInt(Date.now()) * 1000000n).toString().padStart(19, "0")}-${Math.random().toString(16).slice(2, 10)}`
        const tmp = path.join(QUEUE, stem + ".tmp")
        writeFileSync(tmp, JSON.stringify(item))
        renameSync(tmp, path.join(QUEUE, stem + ".json"))
      } catch { /* full disk shouldn't crash opencode */ }
    },
  }
}
