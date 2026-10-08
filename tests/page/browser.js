// A stand-in browser: just enough of one to run the phone page (phone/app.js, with the
// elements of phone/index.html) in node exactly as it is served, so what the page does
// can be tested. Nothing here makes a sound, opens a microphone or touches a network:
//   - the elements are parsed from the real index.html; events go down and up the tree
//     the way a browser sends them (capture, target, bubble; stopPropagation is obeyed);
//   - the clock is moved by hand (`advance`), and Date.now() and every timer follow it;
//   - the voice (`speechSynthesis`) only records what it was handed, and plays the part
//     its `manner` says: a healthy voice, one that never starts, one that goes quiet;
//   - the Mac (`fetch`) answers /api/state from `mac.state` and anything else from
//     `mac.routes`, and records every request.
// It knows nothing about what the page should do: that's run.js.
'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const PHONE = path.join(__dirname, '..', '..', 'phone');

// A terminal's turn as the Mac's /api/state lists it (Phone.state in speak-hud.swift).
function turn(key, text, more = {}) {
  return Object.assign({
    key, name: 'T-' + key, text, at: 1_700_000_000, color: null, canReply: true, question: null, sent: null,
    note: null, box: null, busy: false, status: null, context: null, media: [],
  }, more);
}

// -- what a voice does with something it's handed ------------------------------
// It starts, says each word (told to the page only if `perWord` is given: some of a
// phone's voices report their words and some don't), and finishes.
const speaks = ({ start = 10, perWord = 0, lasts = 200 } = {}) => () => ({ start, perWord, lasts });
// It takes what it's handed and does nothing: no start, no end, nothing in hand.
const mute = () => () => ({ drop: true });
// It starts, reports `words` words, then goes quiet for good while still saying it's speaking.
const hangs = ({ start = 10, words = 0, perWord = 50 } = {}) => () => ({ start, perWord, words, never: true });

function makeWorld(opts = {}) {
  const world = { errors: [], logged: [], scrolledTo: [] };
  const caught = (e) => { world.errors.push(e); };
  // Run something of the page's, keeping what it throws (now or when its promise settles).
  const guard = (fn, ...args) => {
    try {
      const r = fn(...args);
      if (r && typeof r.catch === 'function') r.catch(caught);
    } catch (e) { caught(e); }
  };

  // ---- the clock ----
  let t = 1_700_000_000_000;
  let seq = 0;
  const timers = new Map();
  const clock = {
    now: () => t,
    setTimeout: (fn, ms = 0) => { const id = ++seq; timers.set(id, { fn, at: t + Math.max(0, ms || 0), every: 0 }); return id; },
    setInterval: (fn, ms) => { const id = ++seq; timers.set(id, { fn, at: t + Math.max(1, ms || 0), every: Math.max(1, ms || 0) }); return id; },
    clear: (id) => { timers.delete(id); },
  };
  // Let everything already under way (promises, the fake Mac's answers) run to rest.
  let flying = 0;   // requests the Mac has yet to answer (not the ones held on the line)
  async function settle() {
    for (let turns = 0; turns < 3 || flying > 0; turns++) {
      if (turns > 500) throw new Error('the page never stops asking the Mac');
      await new Promise((r) => setImmediate(r));
    }
  }
  // Move the clock on by `ms`, running each timer at the moment it falls due.
  async function advance(ms) {
    const end = t + ms;
    await settle();
    for (let runs = 0; ; runs++) {
      if (runs > 200000) throw new Error('the page never stops setting timers');
      let due = null;
      for (const [id, x] of timers) if (x.at <= end && (!due || x.at < due.x.at)) due = { id, x };
      if (!due) break;
      t = Math.max(t, due.x.at);
      if (due.x.every) due.x.at += due.x.every; else timers.delete(due.id);
      guard(due.x.fn);
      await settle();
    }
    t = end;
    await settle();
  }

  // ---- the elements ----
  class Target {
    constructor() { this.listeners = []; }
    addEventListener(kind, fn, how) { this.listeners.push({ kind, fn, capture: how === true || !!(how && how.capture) }); }
    dispatchEvent(e) { return send(this, e); }
  }
  class Text {
    constructor(s) { this.data = String(s); this.parent = null; }
    get length() { return this.data.length; }
    get textContent() { return this.data; }
    cloneNode() { return new Text(this.data); }
    remove() { if (this.parent) { this.parent.kids = this.parent.kids.filter((k) => k !== this); this.parent = null; } }
  }
  class El extends Target {
    constructor(tag) {
      super();
      this.tagName = tag.toUpperCase(); this.kids = []; this.parent = null; this.attrs = {}; this.dataset = {};
      this.hidden = false; this.disabled = false; this.value = ''; this.checked = false; this.open = false; this.type = '';
      this.scrollLeft = 0; this.scrollHeight = 0; this.clientHeight = 0; this.clientWidth = 390;
      const cls = this._cls = new Set();
      this.classList = {
        add: (...c) => c.forEach((x) => cls.add(x)), remove: (...c) => c.forEach((x) => cls.delete(x)),
        toggle: (c, on) => { const want = on === undefined ? !cls.has(c) : !!on; if (want) cls.add(c); else cls.delete(c); return want; },
        contains: (c) => cls.has(c),
      };
      const props = {};
      this.style = { setProperty: (k, v) => { props[k] = v; }, removeProperty: (k) => { delete props[k]; }, getPropertyValue: (k) => props[k] || '' };
    }
    get id() { return this.attrs.id || ''; }
    get className() { return [...this._cls].join(' '); }
    set className(v) { this._cls.clear(); String(v).split(/\s+/).filter(Boolean).forEach((c) => this._cls.add(c)); }
    get children() { return this.kids.filter((k) => k instanceof El); }
    get firstElementChild() { return this.children[0] || null; }
    get content() { return { firstElementChild: this.firstElementChild }; }   // a <template>'s
    get offsetWidth() { return 0; }
    get textContent() { return this.kids.map((k) => k.textContent).join(''); }
    set textContent(v) { this.replaceChildren(); if (v !== '' && v != null) this.append(String(v)); }
    setAttribute(k, v) {
      this.attrs[k] = String(v);
      if (k === 'class') this.className = v;
      if (k === 'type') this.type = String(v);
      if (k === 'hidden') this.hidden = true;
      if (k.startsWith('data-')) this.dataset[k.slice(5)] = String(v);
    }
    getAttribute(k) { return k in this.attrs ? this.attrs[k] : null; }
    append(...nodes) {
      for (let n of nodes) {
        if (!(n instanceof El) && !(n instanceof Text)) n = new Text(n);
        n.remove();
        n.parent = this;
        this.kids.push(n);
      }
    }
    appendChild(n) { this.append(n); return n; }
    replaceChildren(...nodes) { for (const k of this.kids) k.parent = null; this.kids = []; this.append(...nodes); }
    remove() { if (this.parent) { this.parent.kids = this.parent.kids.filter((k) => k !== this); this.parent = null; } }
    contains(n) { for (; n; n = n.parent) if (n === this) return true; return false; }
    cloneNode(deep) {
      const c = new El(this.tagName);
      c.attrs = { ...this.attrs }; c.dataset = { ...this.dataset }; c.hidden = this.hidden; c.type = this.type; c.className = this.className;
      if (deep) for (const k of this.kids) c.append(k.cloneNode(true));
      return c;
    }
    // tag, #id, .class and [attr="value"], in any mix: all the page's own code asks for.
    matches(sel) {
      const m = /^([a-z][\w-]*)?((?:[.#][\w-]+)*)(?:\[([\w-]+)="([^"]*)"\])?$/i.exec(sel);
      if (!m) throw new Error('a selector the stand-in browser does not know: ' + sel);
      if (m[1] && this.tagName !== m[1].toUpperCase()) return false;
      for (const part of (m[2] || '').match(/[.#][\w-]+/g) || []) {
        if (part[0] === '.' ? !this._cls.has(part.slice(1)) : this.id !== part.slice(1)) return false;
      }
      if (m[3] && (m[3] === 'type' ? this.type : this.attrs[m[3]]) !== m[4]) return false;
      return true;
    }
    *walk() { for (const k of this.kids) if (k instanceof El) { yield k; yield* k.walk(); } }
    querySelector(sel) { return this.querySelectorAll(sel)[0] || null; }
    querySelectorAll(sel) {
      const parts = sel.trim().split(/\s+/);
      const found = [];
      for (const el of this.walk()) {
        if (!el.matches(parts[parts.length - 1])) continue;
        let ok = true;
        let up = el.parent;
        for (let i = parts.length - 2; i >= 0 && ok; i--) {
          while (up && up !== this.parent && !(up instanceof El && up.matches(parts[i]))) up = up.parent;
          if (!up || up === this.parent) ok = false; else up = up.parent;
        }
        if (ok) found.push(el);
      }
      return found;
    }
    closest(sel) { for (let e = this; e; e = e.parent) if (e instanceof El && e.matches(sel)) return e; return null; }
    // A click, and what a browser then does by itself: a tick box flips and says it
    // changed, a submit button sends its form, a <summary> opens or shuts its <details>.
    click() {
      if (this.disabled) return;
      const box = this.tagName === 'INPUT' && this.type === 'checkbox';
      if (box) this.checked = !this.checked;
      const went = send(this, { type: 'click', bubbles: true });
      if (!went) { if (box) this.checked = !this.checked; return; }
      if (box) { send(this, { type: 'input', bubbles: true }); send(this, { type: 'change', bubbles: true }); }
      const form = this.type === 'submit' && this.tagName === 'BUTTON' ? this.closest('form') : null;
      if (form) form.requestSubmit();
      if (this.tagName === 'SUMMARY' && this.parent instanceof El && this.parent.tagName === 'DETAILS') {
        this.parent.open = !this.parent.open;
        send(this.parent, { type: 'toggle', bubbles: false });
      }
    }
    requestSubmit() { send(this, { type: 'submit', bubbles: true }); }
    focus() { document.activeElement = this; }
    blur() { if (document.activeElement === this) document.activeElement = document.body; }
    scrollIntoView() { world.scrolledTo.push(this.dataset.key || this.id || this.tagName); }
    getBoundingClientRect() { return { top: 0, left: 0, width: 0, height: 0 }; }
    getContext() { return { fillRect() {}, drawImage() {} }; }
  }
  class Range {
    setStart(node, at) { this.node = node; this.start = at; }
    setEnd(node, at) { this.end = at; }
    getClientRects() { return []; }
    getBoundingClientRect() { return { top: 0, left: 0, width: 0, height: 0 }; }
  }

  // An event on its way: down from the window to the target, then back up.
  function send(target, e) {
    const chain = [];
    for (let n = target; n; n = n.parent) chain.push(n);
    const top = chain[chain.length - 1];
    if (top === root) chain.push(document);
    if (top === root || top === document) chain.push(win);
    let stopped = false;
    let atOnce = false;
    e.target = target;
    e.defaultPrevented = false;
    e.preventDefault = () => { e.defaultPrevented = true; };
    e.stopPropagation = () => { stopped = true; };
    e.stopImmediatePropagation = () => { stopped = atOnce = true; };
    const run = (node, capture) => {
      for (const l of node.listeners.slice()) {
        if (atOnce) return;
        if (l.kind !== e.type || (capture !== null && l.capture !== capture)) continue;
        e.currentTarget = node;
        guard(l.fn, e);
      }
    };
    for (let i = chain.length - 1; i > 0 && !stopped; i--) run(chain[i], true);
    if (!stopped) run(target, null);
    if (e.bubbles !== false) for (let i = 1; i < chain.length && !stopped; i++) run(chain[i], false);
    return !e.defaultPrevented;
  }

  function parse(html) {
    const top = new El('#root');
    const stack = [top];
    const alone = new Set(['meta', 'link', 'input', 'path', 'rect', 'circle', 'br', 'img', '!doctype']);
    const plain = (s) => s.replace(/&#(\d+);/g, (_, n) => String.fromCodePoint(Number(n))).replace(/&amp;/g, '&');
    const re = /<(\/?)([!\w-]+)([^>]*)>|([^<]+)/g;
    for (let m; (m = re.exec(html.replace(/<!--[\s\S]*?-->/g, '')));) {
      if (m[4] !== undefined) { if (m[4].trim()) stack[stack.length - 1].append(new Text(plain(m[4].trim()))); continue; }
      const tag = m[2].toLowerCase();
      if (m[1]) { stack.pop(); continue; }
      if (tag === '!doctype') continue;
      const el = new El(tag);
      for (const a of m[3].matchAll(/([\w-]+)(?:="([^"]*)")?/g)) el.setAttribute(a[1], a[2] === undefined ? '' : plain(a[2]));
      stack[stack.length - 1].append(el);
      if (!alone.has(tag) && !m[3].trim().endsWith('/')) stack.push(el);
    }
    return top;
  }

  const root = parse(fs.readFileSync(path.join(PHONE, 'index.html'), 'utf8'));
  const byId = {};
  for (const el of root.walk()) if (el.id) byId[el.id] = el;
  const document = new Target();
  const win = new Target();
  Object.assign(document, {
    hidden: false, documentElement: root.querySelector('html'), body: root.querySelector('body'), activeElement: null,
    getElementById: (id) => byId[id] || null,
    createElement: (tag) => new El(tag),
    createTextNode: (s) => new Text(s),
  });
  document.activeElement = document.body;

  // ---- the voice ----
  const said = [];       // everything handed to the voice, in order
  const waiting = [];    // handed over and not begun
  let current = null;    // { u, timers } being said
  const tell = (u, kind, more) => { const fn = u['on' + kind]; if (fn) guard(fn, Object.assign({ type: kind, utterance: u }, more)); };
  function begin() {
    while (!current && waiting.length) {
      const u = waiting.shift();
      const plan = voice.manner(u);
      if (plan.drop) continue;
      const mine = current = { u, timers: [] };
      const at = (ms, fn) => mine.timers.push(clock.setTimeout(() => { if (current === mine) fn(); }, ms));
      at(plan.start, () => tell(u, 'start'));
      const words = [...String(u.text).matchAll(/\S+/g)];
      const told = plan.never ? words.slice(0, plan.words) : (plan.perWord ? words : []);
      told.forEach((w, i) => at(plan.start + i * plan.perWord + 1, () => tell(u, 'boundary', { name: 'word', charIndex: w.index, charLength: w[0].length })));
      if (!plan.never) {
        at(plan.start + (plan.perWord ? words.length * plan.perWord + 1 : plan.lasts), () => {
          current = null;
          voice.speaking = waiting.length > 0;
          tell(u, 'end');
          begin();
        });
      }
    }
    voice.speaking = !!current;
    voice.pending = !!current && waiting.length > 0;
  }
  const voice = {
    speaking: false, pending: false, cancels: 0, said,
    manner: opts.manner || speaks(),
    texts: () => said.map((u) => u.text),
    speak(u) { said.push(u); waiting.push(u); begin(); },
    // Everything in hand is dropped; what was being said hears of it, as a phone tells it.
    cancel() {
      voice.cancels++;
      const was = current;
      current = null;
      waiting.length = 0;
      voice.speaking = voice.pending = false;
      if (was) { was.timers.forEach(clock.clear); clock.setTimeout(() => tell(was.u, 'error', { error: 'canceled' }), 0); }
    },
    getVoices: () => opts.voices || [],
    addEventListener() {},
  };
  class Utterance { constructor(text) { this.text = String(text); this.rate = 1; this.volume = 1; } }

  // ---- the Mac ----
  const requests = [];
  const mac = {
    state: { away: false, quick: ['Yes'], canHear: true, canHearLive: true, turns: [] },
    routes: {},      // path -> (request) => ({ status, data }), for anything but the plain answers below
    down: false,     // true: nothing gets through, as when the Mac sleeps or the phone is off the tailnet
    requests,
    posts: (p) => requests.filter((r) => r.method === 'POST' && r.path === p),
    gets: (p) => requests.filter((r) => r.method === 'GET' && r.path === p),
    // Keep requests for `p` on the line until release() is called.
    hold(p) {
      const line = { waiting: [], release() { delete held[p]; for (const go of line.waiting.splice(0)) go(); } };
      held[p] = line;
      return line;
    },
  };
  const held = {};
  const copy = (x) => (x === undefined ? undefined : JSON.parse(JSON.stringify(x)));
  async function fetch(url, init = {}) {
    const p = String(url).split(/[?#]/)[0];
    const req = { url: String(url), path: p, method: init.method || 'GET', headers: init.headers || {}, body: typeof init.body === 'string' ? JSON.parse(init.body) : init.body };
    requests.push(req);
    if (held[p]) await new Promise((go) => held[p].waiting.push(go));
    // An answer never lands in the moment it was asked for: it takes a turn of its own.
    flying++;
    try { await new Promise((r) => setImmediate(r)); } finally { flying--; }
    if (mac.down) throw new sandbox.TypeError('Load failed');
    let answer;
    if (mac.routes[p]) answer = mac.routes[p](req) || {};
    else if (p === '/api/state') answer = { data: mac.state };
    else if (p === '/api/screen') answer = { data: { screen: 'the foot of its screen', state: mac.state } };
    else answer = { data: { ok: true } };
    const status = answer.status || 200;
    const data = copy(answer.data);
    return { ok: status >= 200 && status < 300, status, json: async () => { if (data === undefined) throw new sandbox.SyntaxError('not JSON'); return data; }, blob: async () => ({ type: '' }) };
  }

  // ---- other tabs of the page ----
  const channels = [];
  class BroadcastChannel {
    constructor(name) { this.name = name; this.posted = []; this.onmessage = null; channels.push(this); }
    postMessage(m) { this.posted.push(m); }
  }

  // ---- a microphone that records nothing (only when a test asks for one) ----
  const mic = { opened: 0, stopped: 0, port: null };
  // What the page's recorder would be handed while someone talks: `ms` of loud sound.
  mic.loud = async (ms) => {
    for (let at = 0; at < ms; at += 50) {
      if (mic.port && mic.port.onmessage) guard(mic.port.onmessage, { data: new Float32Array(2400).fill(0.5) });
      await advance(50);
    }
  };
  class AudioContext {
    constructor() { this.state = 'running'; this.sampleRate = 48000; this.audioWorklet = { addModule: async () => {} }; this.destination = {}; }
    resume() { return Promise.resolve(); }
    close() { return Promise.resolve(); }
    createMediaStreamSource() { return { connect() {} }; }
  }
  class AudioWorkletNode { constructor() { this.port = mic.port = {}; } connect() {} }
  const getUserMedia = async () => { mic.opened++; return { getTracks: () => [{ stop() { mic.stopped++; } }] }; };

  // ---- the page's globals: in a browser `window` is the global itself ----
  const store = new Map(Object.entries(opts.storage || {}));
  class FakeDate extends Date {
    constructor(...a) { if (a.length) super(...a); else super(t); }
    static now() { return t; }
  }
  const sandbox = {
    document,
    navigator: { language: 'en-US', mediaDevices: opts.mic ? { getUserMedia } : undefined },
    location: { hash: opts.hash || '' },
    history: { pushState() {}, back() { send(win, { type: 'popstate', bubbles: false }); } },
    localStorage: { getItem: (k) => (store.has(k) ? store.get(k) : null), setItem: (k, v) => { store.set(k, String(v)); } },
    fetch, Range, TextEncoder, BroadcastChannel,
    Event: class { constructor(type, how) { this.type = type; this.bubbles = !!(how && how.bubbles); } },
    console: { log: (...a) => world.logged.push(a), warn: (...a) => world.logged.push(a), error: (...a) => world.logged.push(a) },
    setTimeout: clock.setTimeout, setInterval: clock.setInterval, clearTimeout: clock.clear, clearInterval: clock.clear,
    requestAnimationFrame: (fn) => clock.setTimeout(fn, 16),
    Date: FakeDate,
    speechSynthesis: opts.noVoice ? undefined : voice,
    SpeechSynthesisUtterance: Utterance,
    addEventListener: (kind, fn, how) => win.addEventListener(kind, fn, how),
    scrollY: 0, innerHeight: 800, scrollTo() {}, isSecureContext: true,
    AudioContext: opts.mic ? AudioContext : undefined,
    AudioWorkletNode: opts.mic ? AudioWorkletNode : undefined,
  };
  sandbox.window = sandbox;
  vm.createContext(sandbox);
  for (const name of ['TypeError', 'SyntaxError']) sandbox[name] = vm.runInContext(name, sandbox);

  Object.assign(world, {
    document, voice, mac, mic, clock, channels, store, advance, settle,
    location: sandbox.location,
    // Load the page: the real script, as served.
    async load() {
      vm.runInContext(fs.readFileSync(path.join(PHONE, 'app.js'), 'utf8'), sandbox, { filename: path.join(PHONE, 'app.js') });
      await settle();
    },
    $: (id) => byId[id] || null,
    wins: () => byId.windows.children,
    win: (key) => byId.windows.children.find((el) => el.dataset.key === key) || null,
    keys: () => byId.windows.children.map((el) => el.dataset.key),
    // A finger on the page: the touch, then the click it makes.
    async tap(el) {
      send(el, { type: 'pointerdown', bubbles: true });
      el.click();
      await settle();
    },
    async type(el, words) {
      el.focus();
      el.value = words;
      send(el, { type: 'input', bubbles: true });
      await settle();
    },
    // Leave the page (another app, the lock button) and come back to it.
    async leave() { document.hidden = true; send(document, { type: 'visibilitychange', bubbles: true }); await settle(); },
    async comeBack() { document.hidden = false; send(document, { type: 'visibilitychange', bubbles: true }); await settle(); },
    // Another tab of the page, opened after this one, says it's there.
    async newerTab() {
      for (const channel of channels) if (channel.onmessage) guard(channel.onmessage, { data: { from: 'newer' } });
      await settle();
    },
  });
  return world;
}

module.exports = { makeWorld, turn, speaks, mute, hangs };
