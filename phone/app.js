// The phone page: each terminal's last turn, an answer box for it, and the Away switch.
// It asks the Mac for /api/state every few seconds and redraws in place, so what you
// are typing is never wiped. Turn text only ever goes in as text, never as markup.
// With Read aloud on, the phone's own voice reads turns as they arrive.
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

  const speakSwitch = document.getElementById('speak');
  const speakSays = document.getElementById('speak-says');
  const voice = window.speechSynthesis;
  const canSpeak = !!voice && typeof window.SpeechSynthesisUtterance === 'function';

  const shown = new Map();   // session key -> { el, turn, text, question, note }
  let busy = false;
  let loaded = false;        // the first draw is what was already there, not news
  let wentTo = null;         // the #key already scrolled to

  // -- reading aloud -------------------------------------------------------
  // A phone lets a page speak only after a tap in that visit, so `unlocked` is per
  // page load while the switch itself is remembered.
  let speakOn = false;
  let unlocked = false;
  let reading = null;        // the key being read
  let readId = 0;            // so a cancelled reading's end can't end the next one
  const line = [];           // [key, what] waiting their turn to be read
  let now = null;            // what's being read: { key, what, parts, at }
  // Each tap on the speed button is the next of these; the phone's voice takes a rate.
  const SPEEDS = [1, 1.25, 1.5, 1.75, 2, 0.75];
  const speedButton = document.getElementById('speed');
  let speed = 1;
  const asked = new Map();   // key -> timer: a question's pieces settle before it's read

  function remembered() { try { return localStorage.getItem('speak') === '1'; } catch (e) { return false; } }
  function remember(on) { try { localStorage.setItem('speak', on ? '1' : '0'); } catch (e) { /* private mode */ } }

  function paragraphs(text) {
    return (text || '').split(/\n+/).map((p) => p.replace(/^\s*[-*\u2022]\s*/, '').trim()).filter(Boolean);
  }

  // What to say for a window: who it is, then its turn, its question, or both.
  function wordsFor(turn, what) {
    const parts = [];
    if (what !== 'question') parts.push(turn.name + '.', ...paragraphs(turn.text));
    if (what !== 'turn' && turn.question) {
      parts.push(what === 'question' ? turn.name + ' is asking.' : 'It is asking.', ...paragraphs(turn.question));
    }
    return parts;
  }

  function mark() {
    for (const [key, w] of shown) {
      const button = w.el.querySelector('.win-read');
      button.classList.toggle('is-reading', key === reading);
      button.textContent = key === reading ? 'Stop' : 'Read';
    }
    speakSays.hidden = !speakOn;
    speakSays.textContent = unlocked
      ? 'This phone reads new turns aloud while this page is open.'
      : 'Tap anywhere once and this phone will read new turns aloud.';
  }

  function utter(words) {
    const said = new window.SpeechSynthesisUtterance(words);
    said.lang = navigator.language || 'en-US';
    said.rate = speed;
    return said;
  }

  // Read a window. `from` picks a reading back up where it was (a change of speed:
  // a voice can't change rate mid-sentence, so the sentence starts again).
  function read(key, what, from) {
    const w = shown.get(key);
    if (!canSpeak || !w || !w.turn) return next();
    voice.cancel();
    const mine = ++readId;
    const parts = from ? from.parts : wordsFor(w.turn, what);
    const start = from ? from.at : 0;
    if (start >= parts.length) { reading = null; now = null; return next(); }
    reading = key;
    unlocked = true;
    now = { key, what, parts, at: start };
    parts.slice(start).forEach((part, i) => {
      const said = utter(part);
      said.onstart = () => { if (mine === readId) now.at = start + i; };
      if (start + i === parts.length - 1) {
        said.onend = said.onerror = () => { if (mine === readId) { reading = null; now = null; next(); } };
      }
      voice.speak(said);
    });
    mark();
  }

  function next() {
    const waiting = line.shift();
    if (waiting) read(waiting[0], waiting[1]); else mark();
  }

  function hush() {
    readId++;
    if (canSpeak) voice.cancel();
    reading = null;
    now = null;
    mark();
  }

  function showSpeed() { speedButton.textContent = 'Speed ' + speed + '\u00d7'; }

  // News for a window: read it now, or after what's being read.
  function announce(key, what) {
    if (!speakOn || !unlocked || document.hidden) return;
    if (line.some((l) => l[0] === key && l[1] === what)) return;
    if (reading) line.push([key, what]); else read(key, what);
  }

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
    loaded = true;
    mark();
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
        } else if (data.pasted) {
          // The words are sitting in its prompt, after something that was already
          // there. Sending again would paste them twice: show the prompt instead.
          box.value = '';
          box.style.height = 'auto';
          if (data.state) show(data.state);
          note(el, 'Typed into its prompt but not sent: something was already there. Check its screen below, then Enter sends it.');
          screen.open = true;
          return;
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

    const readButton = el.querySelector('.win-read');
    readButton.hidden = !canSpeak;
    readButton.addEventListener('click', () => {
      if (reading === turn.key) return hush();
      line.length = 0;
      read(turn.key, 'all');
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
    w.turn = turn;
    const frame = /^#[0-9a-f]{6}$/i.test(turn.color || '') ? turn.color : accent(turn.name);
    el.style.setProperty('--frame', frame);
    el.style.setProperty('--on-frame', inkOn(frame));
    el.querySelector('.win-name').textContent = turn.name;
    el.querySelector('.win-when').textContent = ago(turn.at);

    const text = el.querySelector('.win-text');
    const more = el.querySelector('.win-more');
    if (w.text !== turn.text) {
      w.text = turn.text;
      w.note = '';
      text.textContent = turn.text;
      text.hidden = !turn.text;
      text.classList.add('is-clamped');
      more.hidden = text.scrollHeight <= text.clientHeight + 1;
      if (loaded) {
        el.classList.remove('is-new');
        void el.offsetWidth;   // restart the arrival flash
        el.classList.add('is-new');
        if (turn.text) announce(turn.key, 'turn');
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
      // A question comes in two pieces a few seconds apart: read it once, whole.
      clearTimeout(asked.get(turn.key));
      if (turn.question && loaded) {
        asked.set(turn.key, setTimeout(() => announce(turn.key, 'question'), 3500));
      }
    }
    asks.hidden = !turn.question;

    const working = !!turn.sent && !turn.question;
    el.classList.toggle('is-working', working);
    const sent = el.querySelector('.win-sent');
    // A terminal that's open but hasn't finished a turn since it was first seen.
    const idle = !turn.text && !turn.question && !turn.sent;
    sent.textContent = turn.sent ? 'You sent: ' + turn.sent
      : idle ? 'No finished turn from this terminal yet. Its screen shows where it is.' : '';
    sent.hidden = !turn.sent && !idle;

    const form = el.querySelector('.win-answer');
    const words = w.note || (turn.note ? 'Not sent: ' + turn.note + '.' : '');
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

  if (canSpeak) {
    try { speed = SPEEDS.includes(Number(localStorage.getItem('speed'))) ? Number(localStorage.getItem('speed')) : 1; } catch (e) { /* private mode */ }
    speedButton.hidden = false;
    showSpeed();
    speedButton.addEventListener('click', () => {
      speed = SPEEDS[(SPEEDS.indexOf(speed) + 1) % SPEEDS.length];
      try { localStorage.setItem('speed', String(speed)); } catch (e) { /* private mode */ }
      showSpeed();
      if (reading && now) read(now.key, now.what, now);   // hear the new speed at once
    });
    document.getElementById('speak-switch').hidden = false;
    speakOn = remembered();
    speakSwitch.checked = speakOn;
    speakSwitch.addEventListener('change', () => {
      speakOn = speakSwitch.checked;
      remember(speakOn);
      if (speakOn) {
        // Said from this tap, which is also what lets the page speak from now on.
        unlocked = true;
        voice.speak(utter('Reading aloud.'));
      } else {
        line.length = 0;
        hush();
      }
      mark();
    });
    // Switch left on from a last visit: the first tap anywhere lets the page speak
    // again, and if a push brought you to a window, that's the one it reads.
    document.addEventListener('click', (e) => {
      if (!speakOn || unlocked || e.target === speakSwitch) return;
      unlocked = true;
      if (e.target.closest('.win-read')) return;   // that tap reads its own window
      const quiet = new window.SpeechSynthesisUtterance(' ');
      quiet.volume = 0;
      voice.speak(quiet);
      if (wentTo && shown.has(wentTo)) announce(wentTo, 'all');
      mark();
    }, true);
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
