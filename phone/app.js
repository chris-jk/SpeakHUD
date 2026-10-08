// The phone page: each terminal's last turn, an answer box for it, and the Away switch.
// It asks the Mac for /api/state every few seconds and redraws in place, so what you
// are typing is never wiped. Turn text only ever goes in as text, never as markup.
'use strict';
(() => {
  const POLL_MS = 2500;
  // The HUD's colours for a terminal with no frame colour of its own: the same hash
  // and order as Accent in speak-hud.swift, so a name gets the same colour in both.
  const PALETTE = ['#007aff', '#34c759', '#ff9500', '#af52de', '#30b0c7', '#ff2d55', '#5856d6', '#a2845e'];
  const OPTION = /^\s*(?:[-*•]\s*)?([1-9])\.\s+(.+)$/;

  const list = document.getElementById('windows');
  const template = document.getElementById('window');
  const awaySwitch = document.getElementById('away');
  const awaySays = document.getElementById('away-says');
  const trouble = document.getElementById('trouble');
  const empty = document.getElementById('empty');

  const shown = new Map();   // session key -> { el, text, question }
  let busy = false;
  let wentTo = null;         // the #key already scrolled to

  function accent(name) {
    let h = 5381n;
    for (const byte of new TextEncoder().encode(name)) h = (h * 33n + BigInt(byte)) & 0xffffffffffffffffn;
    return PALETTE[Number(h % BigInt(PALETTE.length))];
  }

  // Black or white, whichever reads better on `hex`.
  function inkOn(hex) {
    const n = parseInt(hex.slice(1), 16);
    const lin = (c) => { c /= 255; return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4); };
    const lum = 0.2126 * lin(n >> 16) + 0.7152 * lin((n >> 8) & 255) + 0.0722 * lin(n & 255);
    return lum > 0.179 ? '#101216' : '#ffffff';
  }

  function ago(at) {
    const s = Math.max(0, Date.now() / 1000 - at);
    if (s < 60) return 'now';
    if (s < 3600) return Math.floor(s / 60) + ' min';
    if (s < 86400) return Math.floor(s / 3600) + ' h';
    return Math.floor(s / 86400) + ' d';
  }

  function say(problem) {
    trouble.textContent = problem;
    trouble.hidden = !problem;
  }

  async function call(path, body) {
    const res = await fetch(path, body === undefined ? {} : {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-SpeakHUD': '1' },
      body: JSON.stringify(body),
    });
    let data = {};
    try { data = await res.json(); } catch (e) { /* not JSON: the status says enough */ }
    return { ok: res.ok, status: res.status, data };
  }

  async function refresh() {
    if (busy) return;
    busy = true;
    try {
      const { ok, status, data } = await call('/api/state');
      if (status === 401) {
        say("This phone isn't paired with the Mac any more. On the Mac, open SpeakHUD's menu: Phone, Pair a Phone.");
      } else if (!ok) {
        say('The Mac answered, but not with your terminals. Restart SpeakHUD on the Mac.');
      } else {
        say('');
        show(data);
      }
    } catch (e) {
      say("Can't reach the Mac. It may be asleep, or this phone is off your tailnet.");
    } finally {
      busy = false;
    }
  }

  function show(state) {
    if (!state || !Array.isArray(state.turns)) return;
    awaySwitch.checked = !!state.away;
    awaySays.textContent = state.away
      ? 'Finished turns are pushed to this phone. The Mac stays quiet and awake.'
      : 'The Mac reads turns aloud as usual. Switch on when you walk away.';

    const keys = state.turns.map((t) => t.key);
    for (const [key, w] of shown) {
      if (!keys.includes(key)) { w.el.remove(); shown.delete(key); }
    }
    for (const turn of state.turns) update(turn);

    // Newest first, but never shuffle the page under a keyboard.
    const typing = document.activeElement && document.activeElement.tagName === 'TEXTAREA';
    const order = Array.from(list.children).map((el) => el.dataset.key);
    if (!typing && order.join('\n') !== keys.join('\n')) {
      for (const key of keys) list.appendChild(shown.get(key).el);
    }
    empty.hidden = keys.length > 0;
    goToHash();
  }

  function build(turn) {
    const el = template.content.firstElementChild.cloneNode(true);
    el.dataset.key = turn.key;
    const text = el.querySelector('.win-text');
    const more = el.querySelector('.win-more');
    const form = el.querySelector('.win-answer');
    const box = form.querySelector('textarea');
    const send = form.querySelector('button');
    const screen = el.querySelector('.win-screen');

    more.addEventListener('click', () => {
      text.classList.remove('is-clamped');
      more.hidden = true;
    });

    box.addEventListener('input', () => {
      box.style.height = 'auto';
      box.style.height = box.scrollHeight + 2 + 'px';
    });
    box.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' && !e.shiftKey && !e.isComposing) { e.preventDefault(); form.requestSubmit(); }
    });
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const words = box.value.trim();
      if (!words || send.disabled) return;
      send.disabled = true;
      send.textContent = 'Sending';
      try {
        const { data } = await call('/api/reply', { key: turn.key, text: words });
        if (data.sent) {
          note(el, '');
          // Only what was sent is cleared: anything typed since stays.
          if (box.value.trim() === words) {
            box.value = '';
            box.style.height = 'auto';
            box.blur();
          }
        } else {
          note(el, 'Not sent: ' + (data.outcome || data.error || 'the Mac did not say why') + '.');
        }
        if (data.state) show(data.state);
      } catch (err) {
        note(el, "Not sent: can't reach the Mac.");
      } finally {
        send.disabled = false;
        send.textContent = 'Send';
      }
    });

    screen.addEventListener('toggle', () => { if (screen.open) look(turn.key); });
    el.querySelector('.win-keys').addEventListener('click', (e) => {
      const key = e.target.closest('button');
      if (key) press(turn.key, key.dataset.press, key);
    });
    el.querySelector('.win-options').addEventListener('click', (e) => {
      const option = e.target.closest('button');
      if (option) press(turn.key, option.dataset.press, option);
    });

    list.appendChild(el);
    const w = { el, text: null, question: null, note: '' };
    shown.set(turn.key, w);
    return w;
  }

  // A line under the turn: why something didn't go, or (plain) a fact about the window.
  function note(el, words, plain) {
    const w = shown.get(el.dataset.key);
    if (w && !plain) w.note = words;
    const line = el.querySelector('.win-note');
    line.textContent = words;
    line.hidden = !words;
    line.classList.toggle('is-plain', !!plain);
  }

  function update(turn) {
    const w = shown.get(turn.key) || build(turn);
    const el = w.el;
    const frame = /^#[0-9a-f]{6}$/i.test(turn.color || '') ? turn.color : accent(turn.name);
    el.style.setProperty('--frame', frame);
    el.style.setProperty('--on-frame', inkOn(frame));
    el.querySelector('.win-name').textContent = turn.name;
    el.querySelector('.win-when').textContent = ago(turn.at);

    const text = el.querySelector('.win-text');
    const more = el.querySelector('.win-more');
    if (w.text !== turn.text) {
      const first = w.text === null;
      w.text = turn.text;
      w.note = '';
      text.textContent = turn.text;
      text.hidden = !turn.text;
      text.classList.add('is-clamped');
      more.hidden = text.scrollHeight <= text.clientHeight + 1;
      if (!first) {
        el.classList.remove('is-new');
        void el.offsetWidth;   // restart the arrival flash
        el.classList.add('is-new');
      }
    }

    const asks = el.querySelector('.win-asks');
    if (w.question !== turn.question) {
      w.question = turn.question;
      const options = el.querySelector('.win-options');
      options.replaceChildren();
      const said = [];
      for (const line of (turn.question || '').split('\n')) {
        const m = OPTION.exec(line);
        if (!m) { if (line.trim()) said.push(line.trim()); continue; }
        const button = document.createElement('button');
        button.type = 'button';
        button.dataset.press = m[1];
        const number = document.createElement('b');
        number.textContent = m[1];
        const label = document.createElement('span');
        label.textContent = m[2];
        button.append(number, label);
        options.append(button);
      }
      el.querySelector('.win-question').textContent = said.join('\n');
    }
    asks.hidden = !turn.question;

    const working = !!turn.sent && !turn.question;
    el.classList.toggle('is-working', working);
    const sent = el.querySelector('.win-sent');
    sent.textContent = turn.sent ? 'You sent: ' + turn.sent : '';
    sent.hidden = !turn.sent;

    const form = el.querySelector('.win-answer');
    const words = turn.note ? 'Not sent: ' + turn.note + '.' : w.note;
    if (!turn.canReply) {
      form.hidden = true;
      note(el, "This terminal can't be answered from the phone. Only iTerm2 panes can.", true);
    } else {
      // A question box takes keys, not words: its choices are the buttons above.
      form.hidden = !!turn.question;
      note(el, words);
    }

    const screen = el.querySelector('.win-screen');
    screen.hidden = !turn.canReply;
    if (screen.open || turn.question) look(turn.key, true);
  }

  // Fetch the foot of a terminal's screen. Quiet ones run from the poll and say nothing
  // when they fail; the Mac also uses the look to notice a question box has closed.
  const looking = new Set();
  async function look(key, quiet) {
    const w = shown.get(key);
    if (!w || looking.has(key)) return;
    looking.add(key);
    const pre = w.el.querySelector('.win-pre');
    try {
      const { ok, data } = await call('/api/screen?key=' + encodeURIComponent(key));
      if (ok) {
        pre.textContent = data.screen;
        pre.scrollLeft = 0;
        // Back at Claude's prompt, the Mac drops the question: drop its box here too.
        const now = data.state && data.state.turns.find((t) => t.key === key);
        if (w.question && now && !now.question) show(data.state);
      } else if (!quiet) {
        pre.textContent = data.error || "Can't read its screen.";
      }
    } catch (e) {
      if (!quiet) pre.textContent = "Can't reach the Mac.";
    } finally {
      looking.delete(key);
    }
  }

  async function press(key, name, button) {
    const w = shown.get(key);
    if (!w || !name) return;
    button.disabled = true;
    try {
      const { data } = await call('/api/key', { key, press: name });
      note(w.el, data.sent ? '' : 'Key not pressed: ' + (data.outcome || data.error || 'the Mac did not say why') + '.');
      // Give the terminal a moment to redraw before reading it back.
      setTimeout(() => look(key), 700);
    } catch (e) {
      note(w.el, "Key not pressed: can't reach the Mac.");
    } finally {
      button.disabled = false;
    }
  }

  // A push's link ends in #<session>: bring that window up.
  function goToHash() {
    const key = decodeURIComponent(location.hash.slice(1));
    if (!key || key === wentTo) return;
    const w = shown.get(key);
    if (!w) return;
    wentTo = key;
    w.el.scrollIntoView({ block: 'start' });
  }

  awaySwitch.addEventListener('change', async () => {
    const on = awaySwitch.checked;
    try {
      const { ok, data } = await call('/api/away', { on });
      if (ok) show(data); else { awaySwitch.checked = !on; say("Away didn't change: the Mac refused."); }
    } catch (e) {
      awaySwitch.checked = !on;
      say("Away didn't change: can't reach the Mac.");
    }
  });

  window.addEventListener('hashchange', () => { wentTo = null; goToHash(); });
  document.addEventListener('visibilitychange', () => { if (!document.hidden) refresh(); });
  setInterval(() => { if (!document.hidden) refresh(); }, POLL_MS);
  refresh();
})();
