// The phone page: each terminal's last turn, an answer box for it, and the Away switch.
// It asks the Mac for /api/state every few seconds and redraws in place, so what you
// are typing is never wiped. Turn text only ever goes in as text, never as markup.
// Pictures, video and sound a turn made come from the Mac too, and show under the turn.
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

  const shown = new Map();   // session key -> { el, turn, text, question, note, paras }
  let quick = [];            // the quick answers, as the Mac keeps them
  // The page only reorders when you're not in the middle of something: not typing, not
  // being read to, and not having touched it in the last few seconds.
  const SETTLE_MS = 6000;
  let touched = 0;
  for (const kind of ['touchstart', 'touchmove', 'wheel', 'pointerdown']) {
    window.addEventListener(kind, () => { touched = Date.now(); }, { passive: true });
  }
  const typing = () => !!document.activeElement && document.activeElement.tagName === 'TEXTAREA';
  const settled = () => !typing() && !reading && !hearing && Date.now() - touched > SETTLE_MS;
  // The word being read is marked by a soft block that sits behind the text and glides
  // from word to word, which the browser's own text highlights can't do: those jump.
  const canMark = true;
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
  let now = null;            // what's being read: { key, what, parts, at, word }
  let paused = null;         // a reading stopped with its place kept, same shape
  let active = true;         // false once another tab of this page has taken over
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

  // What to say for a window: who it is, then its turn, its question, or both. Each
  // part of the turn knows the paragraph on the page it's read from.
  function partsFor(w, what) {
    const turn = w.turn;
    const parts = [];
    if (what !== 'question') {
      parts.push({ say: turn.name + '.' });
      for (const para of w.paras || []) parts.push({ say: para.say, para });
    }
    if (what !== 'turn' && (turn.box || turn.question)) {
      parts.push({ say: what === 'question' ? turn.name + ' is asking.' : 'It is asking.' });
      if (turn.box) {
        for (const say of paragraphs(turn.box.ask)) parts.push({ say });
        for (const row of turn.box.rows) {
          if (row.types) continue;   // "type something" is the field, not a choice to hear
          parts.push({ say: (row.number ? row.number + '. ' : '') + row.label + '.' + (row.detail ? ' ' + row.detail : '') });
        }
      } else {
        for (const say of paragraphs(turn.question)) parts.push({ say });
      }
    }
    return parts;
  }

  // Put a turn's text on the page as one span per paragraph, each remembering what the
  // voice will be given for it and where that starts in the paragraph as shown.
  function layText(el, text) {
    const paras = [];
    el.replaceChildren();
    for (const piece of (text || '').split(/(\n+)/)) {
      if (!piece) continue;
      if (/^\n+$/.test(piece)) { el.append(piece); continue; }
      const say = piece.replace(/^\s*[-*\u2022]\s*/, '').trim();
      if (!say) { el.append(piece); continue; }
      const span = document.createElement('span');
      const node = document.createTextNode(piece);
      span.append(node);
      el.append(span);
      paras.push({ say, span, node, lead: piece.indexOf(say) });
    }
    return paras;
  }

  let marked = null;         // the paragraph span being read
  let cursor = null;         // the block behind the word being read, in that window
  let cursorLine = null;     // the line it's on, to tell a glide along a line from a new line
  function unmark() {
    if (marked) marked.classList.remove('is-speaking');
    marked = null;
    if (cursor) cursor.classList.remove('is-on');
    cursor = null;
    cursorLine = null;
    aim = null;
  }

  // Put the block behind `range` (a word). Along a line it glides; onto a new line it
  // moves at once, since a block flying diagonally across the text is worse than a jump.
  function glideTo(para, range) {
    const body = para.span.closest('.win-body');
    const block = body && body.querySelector('.win-cursor');
    const rects = range.getClientRects();
    const rect = rects.length ? rects[0] : range.getBoundingClientRect();
    if (!block || (!rect.width && !rect.height)) return rect;
    const frame = body.getBoundingClientRect();
    const sameLine = cursor === block && cursorLine !== null && Math.abs(cursorLine - (rect.top - frame.top)) < 4;
    if (cursor && cursor !== block) cursor.classList.remove('is-on');
    cursor = block;
    cursorLine = rect.top - frame.top;
    block.style.transitionDuration = sameLine ? '' : '0ms';
    block.style.width = (rect.width + 6) + 'px';
    block.style.height = (rect.height + 2) + 'px';
    block.style.transform = 'translate(' + (rect.left - frame.left - 3) + 'px,' + (rect.top - frame.top - 1) + 'px)';
    block.classList.add('is-on');
    return rect;
  }

  // What the phone's voice did during a reading, in numbers and a few fixed words, for
  // the Mac's log: voices differ in whether and how they report the word they're on, and
  // a reading that jumps about or cuts off can only be explained from the phone that did
  // it. `why` is what started it, `end` what ended it, `page` which open copy of this page.
  const pageId = Math.random().toString(16).slice(2, 6).padEnd(4, '0');
  let heard = null;
  function tally(end) {
    if (!heard || !heard.parts) { heard = null; return; }
    const report = Object.assign({}, heard, { seconds: Math.round((Date.now() - heard.began) / 1000), end, page: pageId });
    delete report.began; delete report.last; delete report.lastAt;
    heard = null;
    call('/api/heard', report).catch(() => {});
  }

  // Keep the place being read a little above the middle of the screen, the way a
  // teleprompter does: the page eases toward it a little every frame, so it moves in one
  // continuous motion a line at a time and never in jumps. It follows the word itself,
  // so a paragraph taller than the screen can't scroll its own beginning away. Never
  // while you're moving the page yourself.
  const ANCHOR = 0.38;
  let aim = null;            // where the page's scroll is easing to
  let easing = false;
  function ease() {
    const gap = aim === null ? 0 : aim - window.scrollY;
    if (aim === null || Math.abs(gap) < 0.6 || Date.now() - touched < SETTLE_MS) { aim = null; easing = false; return; }
    window.scrollTo(0, window.scrollY + gap * 0.12);
    requestAnimationFrame(ease);
  }
  function keepInView(rect) {
    if (!rect || (!rect.height && !rect.width) || Date.now() - touched < SETTLE_MS) return;
    const most = Math.max(0, document.documentElement.scrollHeight - window.innerHeight);
    const want = Math.max(0, Math.min(most, window.scrollY + rect.top - window.innerHeight * ANCHOR));
    if (Math.abs(want - window.scrollY) < 8) return;
    if (heard && (aim === null || Math.abs(want - aim) > window.innerHeight / 4)) heard.scrolls++;
    aim = want;
    if (!easing) { easing = true; requestAnimationFrame(ease); }
  }

  function spot(para, index, size) {
    const start = Math.min(para.node.length, para.lead + index);
    const range = new Range();
    range.setStart(para.node, start);
    range.setEnd(para.node, Math.min(para.node.length, start + Math.max(size, 1)));
    return range;
  }

  // The voice has started `part`: mark its paragraph and bring its first words into view.
  function follow(part) {
    unmark();
    if (heard) { heard.parts++; heard.last = -1; }
    if (!part.para) return;
    marked = part.para.span;
    marked.classList.add('is-speaking');
    keepInView(spot(part.para, 0, 1).getBoundingClientRect());
  }

  // The voice has reached the word at `index` of what the part says. A word behind the
  // last one is a late report: the mark only ever moves forward.
  function point(part, index, length) {
    if (heard) {
      const at = Date.now();
      heard.words++;
      if (length) heard.sized++;
      if (index < heard.last) heard.backwards++;
      if (heard.lastAt) heard.gap = Math.max(heard.gap, at - heard.lastAt);
      heard.lastAt = at;
    }
    if (heard && index < heard.last) return;
    if (heard) heard.last = index;
    if (now) now.word = index;
    if (!part.para) return;
    const size = length || (part.para.say.slice(index).match(/^\S+/) || [''])[0].length;
    keepInView(glideTo(part.para, spot(part.para, index, size)));
  }

  // A window's button: Read, Pause while it's being read, Resume where it was paused.
  // While it's either, start over and stop sit beside it, where the time was.
  function mark() {
    for (const [key, w] of shown) {
      const button = w.el.querySelector('.win-read');
      const held = !!paused && paused.key === key;
      const live = key === reading || held;
      button.classList.toggle('is-reading', key === reading);
      button.textContent = key === reading ? 'Pause' : held ? 'Resume' : 'Read';
      w.el.querySelector('.win-reading').hidden = !live;
      w.el.querySelector('.win-when').hidden = live;
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

  // Stop whatever the voice is saying. Only when it is saying something: a phone's
  // voice asked to cancel while idle can swallow the start of what it's given next.
  function quiet() {
    if (canSpeak && (voice.speaking || voice.pending)) voice.cancel();
  }

  // Read a window. `from` picks a reading up where it was, at the word it had reached:
  // after a pause, or a change of speed (a voice can't change rate mid-sentence).
  // `why` is what asked for it, for the log.
  function read(key, what, from, why) {
    const w = shown.get(key);
    if (!canSpeak || !w || !w.turn) return next();
    quiet();
    const mine = ++readId;
    const parts = from ? from.parts : partsFor(w, what);
    const start = from ? from.at : 0;
    const word = from ? Math.min(from.word || 0, (parts[start] || { say: '' }).say.length) : 0;
    if (start >= parts.length) { reading = null; now = null; unmark(); return next(); }
    reading = key;
    paused = null;
    unlocked = true;
    now = { key, what, parts, at: start, word };
    if (!heard) {
      heard = { began: Date.now(), parts: 0, words: 0, sized: 0, backwards: 0, gap: 0, scrolls: 0, last: -1, lastAt: 0,
                speed, marks: canMark, voices: voice.getVoices ? voice.getVoices().length : 0, lang: navigator.language || '',
                why: why || 'tap' };
    }
    // The whole turn is opened, so the words being read are there to see.
    w.el.querySelector('.win-text').classList.remove('is-clamped');
    w.el.querySelector('.win-more').hidden = true;
    parts.slice(start).forEach((part, i) => {
      const skip = i === 0 ? word : 0;   // picked up mid-sentence: the rest of it
      const said = utter(part.say.slice(skip));
      said.onstart = () => { if (mine === readId) { now.at = start + i; now.word = skip; follow(part); if (heard) heard.last = skip - 1; } };
      said.onboundary = (e) => {
        if (mine === readId && (!e.name || e.name === 'word')) point(part, skip + (e.charIndex || 0), e.charLength || 0);
      };
      if (start + i === parts.length - 1) {
        said.onend = () => { if (mine === readId) { reading = null; now = null; unmark(); tally('finished'); next(); } };
        said.onerror = () => { if (mine === readId) { reading = null; now = null; unmark(); tally('error'); next(); } };
      }
      voice.speak(said);
    });
    mark();
  }

  function next() {
    const waiting = line.shift();
    if (waiting) read(waiting[0], waiting[1], null, waiting[2]); else mark();
  }

  // Stop reading and forget where it was. `end` says why, for the log.
  function hush(end) {
    readId++;
    quiet();
    reading = null;
    now = null;
    paused = null;
    unmark();
    tally(end || 'stopped');
    mark();
  }

  // Stop reading but keep the place, and its marks on the page: Resume goes on from
  // the word it had reached.
  function pause(end) {
    if (!reading || !now) return;
    paused = { key: now.key, what: now.what, parts: now.parts, at: now.at, word: now.word || 0 };
    readId++;
    quiet();
    reading = null;
    now = null;
    tally(end || 'paused');
    mark();
  }

  function carryOn() {
    if (!paused) return;
    const from = paused;
    read(from.key, from.what, from, 'resume');
  }

  function showSpeed() { speedButton.textContent = 'Speed ' + speed + '\u00d7'; }

  // News for a window: read it now, or after what's being read. Not over a reading
  // you've paused, and not from a copy of the page that another tab has taken over from.
  function announce(key, what, why) {
    if (!speakOn || !unlocked || document.hidden || !active || paused) return;
    if (line.some((l) => l[0] === key && l[1] === what)) return;
    if (reading) line.push([key, what, why]); else read(key, what, null, why);
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

  function bytes(n) {
    if (n >= 1e9) return (n / 1e9).toFixed(1) + ' GB';
    if (n >= 1e6) return (n / 1e6).toFixed(n < 1e7 ? 1 : 0) + ' MB';
    return Math.max(1, Math.round(n / 1e3)) + ' KB';
  }

  // One thing a turn made, as the Mac lists it: a picture (a lighter copy; a tap opens
  // the real one), a video or a recording to play here, or anything else as its name
  // to open. The Mac is asked by the turn and the file's place in it, never by a path.
  function piece(key, m) {
    const src = '/api/file?key=' + encodeURIComponent(key) + '&i=' + m.i + '&v=' + encodeURIComponent(m.v);
    const figure = document.createElement('figure');
    figure.className = 'media is-' + m.kind;
    const caption = document.createElement('figcaption');
    const name = document.createElement('a');
    name.href = src;
    name.target = '_blank';
    name.rel = 'noopener';
    name.textContent = m.name;
    const size = document.createElement('small');
    size.textContent = bytes(m.size);
    const save = document.createElement('button');
    save.type = 'button';
    save.className = 'media-save';
    save.textContent = 'Save';
    save.addEventListener('click', () => keep(src + '&save=1', m, save));
    caption.append(name, size, save);
    // Gone from the Mac since it was listed, or a kind this phone can't show.
    const failed = () => {
      figure.classList.add('is-gone');
      size.textContent = bytes(m.size) + ". Can't be shown here: tap its name to open it.";
    };
    if (m.kind === 'image') {
      const open = document.createElement('a');
      open.href = src;
      open.target = '_blank';
      open.rel = 'noopener';
      const img = document.createElement('img');
      img.alt = m.name;
      img.decoding = 'async';
      img.addEventListener('error', failed);
      img.src = src + '&w=1200';
      open.append(img);
      figure.append(open);
    } else if (m.kind === 'video' || m.kind === 'audio') {
      const player = document.createElement(m.kind);
      player.controls = true;
      player.preload = 'metadata';
      if (m.kind === 'video') {
        player.playsInline = true;
        player.setAttribute('playsinline', '');
      }
      player.addEventListener('error', failed);
      // A phone shows a video's first frame only once it has been taken a little way in.
      player.src = src + (m.kind === 'video' ? '#t=0.001' : '');
      figure.append(player);
    }
    figure.append(caption);
    return figure;
  }

  // Save a file a turn made onto the phone. Where the phone can hand a file to its share
  // sheet (on an iPhone that's where Save Image and Save Video put it in Photos, beside
  // Save to Files and AirDrop), the file is fetched and handed over. A very big one, or
  // a phone that can't, gets a plain download, which lands in its downloads.
  const HAND_OVER_LIMIT = 150 * 1024 * 1024;
  const fetched = new Map();   // address -> the file, fetched and waiting for a tap
  async function keep(src, m, button) {
    const download = () => {
      const link = document.createElement('a');
      link.href = src;
      link.download = m.name;
      document.body.append(link);
      link.click();
      link.remove();
    };
    if (typeof navigator.canShare !== 'function' || typeof window.File !== 'function' || m.size > HAND_OVER_LIMIT) return download();
    try {
      let file = fetched.get(src);
      if (!file) {
        button.disabled = true;
        button.textContent = 'Getting it';
        const res = await fetch(src);
        if (!res.ok) throw new Error('gone');
        const blob = await res.blob();
        file = new window.File([blob], m.name, { type: blob.type || 'application/octet-stream' });
        button.disabled = false;
        button.textContent = 'Save';
        if (!navigator.canShare({ files: [file] })) return download();
        fetched.set(src, file);
      }
      await navigator.share({ files: [file] });
      fetched.delete(src);
      button.textContent = 'Save';
    } catch (e) {
      button.disabled = false;
      // A phone only opens its share sheet straight off a tap. A file that took a while
      // to fetch has outlived the tap that asked for it: it's kept, and the next tap opens the sheet.
      if (e && e.name === 'NotAllowedError' && fetched.has(src)) { button.textContent = 'Tap to save'; return; }
      button.textContent = 'Save';
      if (e && e.name === 'AbortError') return;   // you closed the sheet
      fetched.delete(src);
      download();
    }
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
    if (busy || !active) return;
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

    if (Array.isArray(state.quick) && state.quick.join('\n') !== quick.join('\n')) {
      quick = state.quick;
      drawQuickList();
    }
    canHear = !!state.canHear;
    // Decided before anything new starts being read: a turn that has just arrived
    // comes to the top and is read there, and then the page holds still.
    const still = settled();
    const keys = state.turns.map((t) => t.key);
    for (const [key, w] of shown) {
      if (!keys.includes(key)) { w.el.remove(); shown.delete(key); }
    }
    for (const turn of state.turns) update(turn);

    // Newest first, but never shuffle the page under a keyboard, a reading, or a thumb.
    const order = Array.from(list.children).map((el) => el.dataset.key);
    if (still && order.join('\n') !== keys.join('\n')) {
      for (const key of keys) list.appendChild(shown.get(key).el);
    }
    empty.hidden = keys.length > 0;
    goToHash();
    loaded = true;
    mark();
    drawMics();
  }

  function build(turn) {
    const el = template.content.firstElementChild.cloneNode(true);
    el.dataset.key = turn.key;
    const text = el.querySelector('.win-text');
    const more = el.querySelector('.win-more');
    const form = el.querySelector('.win-answer');
    const box = form.querySelector('textarea');
    const send = form.querySelector('button[type="submit"]');
    form.querySelector('.win-mic').addEventListener('click', () => {
      if (hearing && hearing.key === turn.key) finish(hearing);   // done talking: off to the Mac
      else if (!hearing) listen(turn.key);
    });
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
    // Send `words` to this terminal: what's in the box (cleared once it has gone), or
    // a quick answer.
    async function sendWords(words, button, fromBox) {
      if (!words || button.disabled) return;
      button.disabled = true;
      if (fromBox) button.textContent = 'Sending';
      try {
        const { data } = await call('/api/reply', { key: turn.key, text: words });
        if (data.sent) {
          note(el, '');
          // Only what was sent is cleared: anything typed since stays.
          if (fromBox && box.value.trim() === words) {
            box.value = '';
            box.style.height = 'auto';
            box.blur();
          }
        } else if (data.pasted) {
          // The words are sitting in its prompt, after something that was already
          // there. Sending again would paste them twice: show the prompt instead.
          if (fromBox) { box.value = ''; box.style.height = 'auto'; }
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
        button.disabled = false;
        if (fromBox) button.textContent = shown.get(turn.key) && shown.get(turn.key).turn.busy ? 'Queue' : 'Send';
      }
    }
    form.addEventListener('submit', (e) => {
      e.preventDefault();
      sendWords(box.value.trim(), send, true);
    });
    el.querySelector('.win-quick').addEventListener('click', (e) => {
      const chip = e.target.closest('button');
      if (chip) sendWords(chip.textContent, chip, false);
    });

    // Closing ends the session in that terminal, so it takes two taps.
    const closeButton = el.querySelector('.win-close');
    let armed = 0;
    const disarm = () => { armed = 0; closeButton.textContent = 'Close this terminal'; closeButton.classList.remove('is-armed'); };
    closeButton.addEventListener('click', async () => {
      if (!armed) {
        armed = Date.now();
        closeButton.textContent = 'Tap again to close it';
        closeButton.classList.add('is-armed');
        setTimeout(() => { if (armed && Date.now() - armed >= 3900) disarm(); }, 4000);
        return;
      }
      disarm();
      closeButton.disabled = true;
      try {
        const { data } = await call('/api/close', { key: turn.key });
        if (data.state) show(data.state);
        if (!data.sent) note(el, 'Not closed: ' + (data.outcome || data.error || 'the Mac did not say why') + '.');
      } catch (err) {
        note(el, "Not closed: can't reach the Mac.");
      } finally {
        closeButton.disabled = false;
      }
    });

    const readButton = el.querySelector('.win-read');
    readButton.hidden = !canSpeak;
    readButton.addEventListener('click', () => {
      touched = 0;   // this tap is a request to be shown the reading, not a hand on the page
      if (reading === turn.key) return pause();
      if (paused && paused.key === turn.key) return carryOn();
      line.length = 0;
      if (reading) hush('replaced'); else { paused = null; unmark(); }
      read(turn.key, 'all', null, 'tap');
    });

    el.querySelector('.win-over').addEventListener('click', () => {
      touched = 0;
      line.length = 0;
      if (reading) hush('replaced'); else { paused = null; unmark(); }
      read(turn.key, 'all', null, 'tap');
    });
    el.querySelector('.win-stop').addEventListener('click', () => hush('stopped'));

    screen.addEventListener('toggle', () => { if (screen.open) look(turn.key); });
    el.querySelector('.win-keys').addEventListener('click', (e) => {
      const key = e.target.closest('button');
      if (key) press(turn.key, key.dataset.press, key);
    });
    el.querySelector('.win-options').addEventListener('click', (e) => {
      const option = e.target.closest('button');
      if (!option || option.type === 'submit') return;
      if (option.dataset.row) pick(turn.key, Number(option.dataset.row), option.dataset.label, option);
      else press(turn.key, option.dataset.press, option);
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

    const status = el.querySelector('.win-status');
    status.textContent = turn.status || '';
    status.hidden = !turn.status;
    status.classList.toggle('is-full', (turn.context || 0) >= 80);

    const text = el.querySelector('.win-text');
    const more = el.querySelector('.win-more');
    if (w.text !== turn.text) {
      w.text = turn.text;
      w.note = '';
      // The words being read, or paused on, are about to be replaced.
      if (reading === turn.key || (paused && paused.key === turn.key)) hush('changed');
      w.paras = layText(text, turn.text);
      text.hidden = !turn.text;
      text.classList.add('is-clamped');
      more.hidden = text.scrollHeight <= text.clientHeight + 1;
      if (loaded) {
        el.classList.remove('is-new');
        void el.offsetWidth;   // restart the arrival flash
        el.classList.add('is-new');
        if (turn.text) announce(turn.key, 'turn', 'arrival');
      }
    }

    // What the turn made. Redrawn only when the list changes, so the next look at the
    // Mac never restarts a video you're watching.
    const media = Array.isArray(turn.media) ? turn.media : [];
    const made = media.map((m) => m.i + ' ' + m.v).join('\n');
    if (w.media !== made) {
      w.media = made;
      const strip = el.querySelector('.win-media');
      strip.replaceChildren(...media.map((m) => piece(turn.key, m)));
      strip.hidden = !media.length;
      strip.classList.toggle('is-many', media.filter((m) => m.kind === 'image').length > 1);
    }

    // What it's asking. The box read off its terminal's screen is the truth; the question
    // hook's words stand in only until the screen has been looked at.
    const asks = el.querySelector('.win-asks');
    const box = turn.box;
    const asking = !!(box || turn.question);
    const drawn = box ? JSON.stringify(box) : (turn.question || '');
    if (w.question !== drawn) {
      w.question = drawn;
      const options = el.querySelector('.win-options');
      options.replaceChildren();
      const tabs = el.querySelector('.win-tabs');
      tabs.textContent = (box && box.tabs) || '';
      tabs.hidden = !tabs.textContent;
      if (box) {
        el.querySelector('.win-question').textContent = box.ask;
        box.rows.forEach((row, index) => options.append(choice(turn.key, row, index)));
      } else {
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
      // Read a question once, whole: the hook's comes in two pieces a few seconds apart,
      // and a box's ticks changing isn't a new question.
      const what = box ? box.ask : (turn.question || '');
      if (what !== w.asked) {
        w.asked = what;
        clearTimeout(asked.get(turn.key));
        if (what && loaded) asked.set(turn.key, setTimeout(() => announce(turn.key, 'question', 'question'), box ? 400 : 3500));
      }
    }
    asks.hidden = !asking;

    // Full colour: it's waiting on you. A stripe: it's working, on its own or on what you sent.
    const working = !asking && (turn.busy || !!turn.sent);
    el.classList.toggle('is-working', working);
    el.querySelector('.win-state').textContent = asking ? 'asking' : '';   // working is said down by the buttons
    // Said down by the buttons too, with a bar that keeps moving: that's where your
    // thumb is when you're about to send it something more.
    el.querySelector('.win-working').hidden = !working;
    const sent = el.querySelector('.win-sent');
    // A terminal that's open but hasn't finished a turn since it was first seen.
    const idle = !turn.text && !asking && !turn.sent;
    sent.textContent = turn.sent ? 'You sent: ' + turn.sent
      : idle ? 'No finished turn from this terminal yet. Its screen shows where it is.' : '';
    sent.hidden = !turn.sent && !idle;
    const sendButton = el.querySelector('.win-answer button[type="submit"]');
    if (!sendButton.disabled) sendButton.textContent = turn.busy ? 'Queue' : 'Send';

    const form = el.querySelector('.win-answer');
    const words = w.note || (turn.note ? 'Not sent: ' + turn.note + '.' : '');
    if (!turn.canReply) {
      form.hidden = true;
      note(el, "This terminal can't be answered from the phone. Only iTerm2 panes can.", true);
    } else {
      // A question box takes keys, not words: its choices are the buttons above.
      form.hidden = asking;
      note(el, words);
    }

    const chips = el.querySelector('.win-quick');
    if (w.quick !== quick.join('\n')) {
      w.quick = quick.join('\n');
      chips.replaceChildren(...quick.map((words) => {
        const chip = document.createElement('button');
        chip.type = 'button';
        chip.textContent = words;
        return chip;
      }));
    }
    chips.hidden = !turn.canReply || asking || !quick.length;

    const screen = el.querySelector('.win-screen');
    screen.hidden = !turn.canReply;
    if (screen.open || asking) look(turn.key, true);
  }

  // One choice of a box: a button, or for the choice that takes words, a field.
  function choice(key, row, index) {
    if (row.types && row.checked === null) {
      const form = document.createElement('form');
      form.className = 'win-own';
      const field = document.createElement('input');
      field.type = 'text';
      field.placeholder = 'Or type your own answer';
      field.setAttribute('aria-label', 'Your own answer');
      field.enterKeyHint = 'send';
      const go = document.createElement('button');
      go.type = 'submit';
      go.textContent = 'Send';
      form.append(field, go);
      form.addEventListener('submit', (e) => {
        e.preventDefault();
        const words = field.value.trim();
        if (words) pick(key, index, row.label, go, words);
      });
      return form;
    }
    const button = document.createElement('button');
    button.type = 'button';
    button.dataset.row = String(index);
    button.dataset.label = row.label;
    const mark = document.createElement('b');
    mark.textContent = row.checked === null ? (row.number || '\u203a') : (row.checked ? '\u2611' : '\u2610');
    const words = document.createElement('span');
    const label = document.createElement('span');
    label.textContent = row.label;
    words.append(label);
    if (row.detail) {
      const detail = document.createElement('small');
      detail.textContent = row.detail;
      words.append(detail);
    }
    button.append(mark, words);
    return button;
  }

  // Tap a choice. The Mac reads the box again before pressing anything, so a box that
  // has moved on is never answered blind; then the screen is read back.
  async function pick(key, row, label, button, text) {
    const w = shown.get(key);
    if (!w) return;
    button.disabled = true;
    try {
      const body = { key, row, label };
      if (text !== undefined) body.text = text;
      const { data } = await call('/api/pick', body);
      note(w.el, data.sent ? '' : 'Not chosen: ' + (data.outcome || data.error || 'the Mac did not say why') + '.');
      if (data.state) show(data.state);
      setTimeout(() => look(key), 700);
    } catch (e) {
      note(w.el, "Not chosen: can't reach the Mac.");
    } finally {
      button.disabled = false;
    }
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
        // The Mac has just read its box afresh: redraw if it isn't what's showing here.
        const now = data.state && data.state.turns.find((t) => t.key === key);
        if (now && (now.box ? JSON.stringify(now.box) : (now.question || '')) !== w.question) show(data.state);
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
      if (reading && now) read(now.key, now.what, now, 'speed');   // hear the new speed at once, from the same word
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
        hush('off');
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
      if (wentTo && shown.has(wentTo)) announce(wentTo, 'all', 'visit');
      mark();
    }, true);
  }

  // -- dictation --------------------------------------------------------------
  // The mic by an answer box: say it instead of typing it. The phone records what you
  // say, the Mac turns the recording into words with its own transcriber (the sound goes
  // from this phone to your Mac and no further), and the words land in the box for you
  // to read over and send. It stops by itself when you stop talking.
  const HEARD_RATE = 16000;      // what the Mac is sent: one channel, 16-bit
  const LOUD = 0.02;             // a stretch this loud is someone talking
  const QUIET_MS = 2000;         // this long quiet once you've spoken: you're done
  const NOTHING_MS = 8000;       // this long with nothing said: stop, and let the Mac say so
  const LONGEST_MS = 120000;
  const AudioContextKind = window.AudioContext || window.webkitAudioContext;
  const canDictate = !!(window.isSecureContext && navigator.mediaDevices && navigator.mediaDevices.getUserMedia
    && AudioContextKind && window.AudioWorkletNode);
  let canHear = false;           // the Mac can turn a recording into words
  let hearing = null;            // the one dictation going: { key, blocks, spoke, began, last, level, ... }

  function micSays(key, words) {
    const w = shown.get(key);
    if (!w) return;
    const line = w.el.querySelector('.win-mic-says');
    line.textContent = words;
    line.hidden = !words;
  }

  // Every window's mic: there if this phone can record and the Mac can hear, red while
  // it's listening to you, and out of reach while another window's is.
  function drawMics() {
    for (const [key, w] of shown) {
      const mic = w.el.querySelector('.win-mic');
      const mine = !!hearing && hearing.key === key;
      mic.hidden = !(canDictate && canHear);
      mic.classList.toggle('is-listening', mine && !hearing.ending);
      mic.classList.toggle('is-working', mine && !!hearing.ending);
      mic.disabled = !!hearing && (!mine || !!hearing.ending);
      mic.setAttribute('aria-label', mine && !hearing.ending ? 'Stop: I have said it' : 'Dictate');
      if (!mine) mic.style.removeProperty('--level');
    }
  }

  // Let go of the phone's microphone.
  function letGo(session) {
    clearInterval(session.timer);
    if (session.stream) for (const track of session.stream.getTracks()) track.stop();
    if (session.context) session.context.close().catch(() => {});
    session.stream = session.context = null;
  }

  async function listen(key) {
    if (hearing || !shown.has(key)) return;
    const session = hearing = { key, blocks: [], spoke: false, level: 0, began: Date.now(), last: Date.now() };
    pause();   // the phone's own voice would be heard as you
    micSays(key, 'Getting the microphone');
    drawMics();
    try {
      // Made and started inside the tap itself: a phone lets a page's sound run only
      // from something you did, and by the time the microphone answers that moment has passed.
      session.context = new AudioContextKind();
      session.context.resume().catch(() => {});
      session.stream = await navigator.mediaDevices.getUserMedia({
        audio: { channelCount: 1, echoCancellation: true, noiseSuppression: true, autoGainControl: true },
      });
      await session.context.audioWorklet.addModule('/mic.js');
      if (session.context.state !== 'running') await session.context.resume();
      session.rate = session.context.sampleRate;
      const node = new AudioWorkletNode(session.context, 'mic');
      node.port.onmessage = (e) => {
        if (hearing !== session || session.ending) return;
        const block = e.data;
        session.blocks.push(block);
        let sum = 0;
        for (let i = 0; i < block.length; i++) sum += block[i] * block[i];
        session.level = Math.sqrt(sum / block.length);
        if (session.level > LOUD) { session.spoke = true; session.last = Date.now(); }
      };
      session.context.createMediaStreamSource(session.stream).connect(node);
      node.connect(session.context.destination);   // it plays nothing; a node that leads nowhere may not run
      session.began = session.last = Date.now();
      session.timer = setInterval(() => {
        if (hearing !== session || session.ending) return;
        const w = shown.get(key);
        if (!w) return finish(session);   // its terminal closed under you
        w.el.querySelector('.win-mic').style.setProperty('--level', String(Math.min(1, session.level * 10)));
        const now = Date.now();
        const quiet = session.spoke ? now - session.last > QUIET_MS : now - session.began > NOTHING_MS;
        if (quiet || now - session.began > LONGEST_MS) finish(session);
      }, 150);
      micSays(key, 'Listening. It stops when you do, or tap the mic.');
    } catch (e) {
      letGo(session);
      hearing = null;
      drawMics();
      const why = (e && e.name) || 'Error';
      micSays(key, why === 'NotAllowedError' || why === 'SecurityError'
        ? "This phone won't let the page use its microphone. Allow the microphone for this site in the browser's settings."
        : "The microphone wouldn't start (" + why + ').');
      missed(why);
    }
  }

  // A dictation that never got as far as the Mac, said to its log by name: nothing on
  // the Mac can see why a phone's microphone didn't start.
  function missed(why) { call('/api/mic', { why }).catch(() => {}); }

  // Everything heard, as one run of samples at the rate the Mac is sent: each sample
  // out is the average of the ones it stands for.
  function gather(blocks, from) {
    let total = 0;
    for (const block of blocks) total += block.length;
    const all = new Float32Array(total);
    let at = 0;
    for (const block of blocks) { all.set(block, at); at += block.length; }
    if (!from || from === HEARD_RATE) return all;
    const step = from / HEARD_RATE;
    const out = new Float32Array(Math.floor(total / step));
    for (let i = 0; i < out.length; i++) {
      const start = Math.floor(i * step);
      const end = Math.max(start + 1, Math.min(total, Math.floor((i + 1) * step)));
      let sum = 0;
      for (let j = start; j < end; j++) sum += all[j];
      out[i] = sum / (end - start);
    }
    return out;
  }

  // Samples as a WAV file: the 44 bytes that say what follows, then 16-bit sound.
  function wav(samples) {
    const view = new DataView(new ArrayBuffer(44 + samples.length * 2));
    const tag = (at, word) => { for (let i = 0; i < 4; i++) view.setUint8(at + i, word.charCodeAt(i)); };
    tag(0, 'RIFF'); view.setUint32(4, 36 + samples.length * 2, true); tag(8, 'WAVE');
    tag(12, 'fmt '); view.setUint32(16, 16, true); view.setUint16(20, 1, true); view.setUint16(22, 1, true);
    view.setUint32(24, HEARD_RATE, true); view.setUint32(28, HEARD_RATE * 2, true);
    view.setUint16(32, 2, true); view.setUint16(34, 16, true);
    tag(36, 'data'); view.setUint32(40, samples.length * 2, true);
    for (let i = 0; i < samples.length; i++) {
      const s = Math.max(-1, Math.min(1, samples[i]));
      view.setInt16(44 + i * 2, s < 0 ? s * 0x8000 : s * 0x7fff, true);
    }
    return view.buffer;
  }

  // You've said it: the microphone goes off at once, the recording goes to the Mac, and
  // its words go on the end of whatever is in the box.
  async function finish(session) {
    if (hearing !== session || session.ending) return;
    session.ending = true;
    const key = session.key;
    const rate = session.rate;
    letGo(session);
    drawMics();
    const samples = gather(session.blocks, rate);
    session.blocks = [];
    if (samples.length < HEARD_RATE / 5) {
      hearing = null;
      drawMics();
      missed('NothingRecorded');
      return micSays(key, 'Nothing was recorded. Tap the mic and say it again.');
    }
    micSays(key, 'Turning it into words');
    try {
      const res = await fetch('/api/hear', {
        method: 'POST',
        headers: { 'Content-Type': 'audio/wav', 'X-SpeakHUD': '1' },
        body: wav(samples),
      });
      let data = {};
      try { data = await res.json(); } catch (e) { /* not JSON: the status says enough */ }
      const w = shown.get(key);
      if (res.ok && data.text && w) {
        const box = w.el.querySelector('.win-answer textarea');
        box.value = (box.value.trim() ? box.value.replace(/\s+$/, '') + ' ' : '') + data.text;
        box.dispatchEvent(new Event('input'));   // the box grows to fit
        micSays(key, '');
      } else if (res.ok) {
        micSays(key, "Didn't catch any words. Tap the mic and say it again.");
      } else {
        micSays(key, 'Not heard: ' + (data.error || 'the Mac did not say why') + '.');
      }
    } catch (e) {
      micSays(key, "Not heard: can't reach the Mac.");
    } finally {
      hearing = null;
      drawMics();
    }
  }

  // A page you've left can't keep the microphone: send what it has.
  document.addEventListener('visibilitychange', () => { if (document.hidden && hearing) finish(hearing); });

  // -- quick answers, kept on the Mac ---------------------------------------
  const quickList = document.getElementById('quick-list');
  const quickNew = document.getElementById('quick-new');

  function drawQuickList() {
    quickList.replaceChildren(...quick.map((words) => {
      const row = document.createElement('li');
      const said = document.createElement('span');
      said.textContent = words;
      const remove = document.createElement('button');
      remove.type = 'button';
      remove.textContent = 'Remove';
      remove.addEventListener('click', () => keepQuick(quick.filter((q) => q !== words), remove));
      row.append(said, remove);
      return row;
    }));
  }

  async function keepQuick(list, button) {
    button.disabled = true;
    try {
      const { ok, data } = await call('/api/quick', { list });
      if (ok) show(data); else say("Quick answers didn't change: the Mac refused.");
    } catch (e) {
      say("Quick answers didn't change: can't reach the Mac.");
    } finally {
      button.disabled = false;
    }
  }

  document.getElementById('quick-add').addEventListener('submit', async (e) => {
    e.preventDefault();
    const words = quickNew.value.trim();
    if (!words) return;
    await keepQuick(quick.concat(words), e.target.querySelector('button'));
    quickNew.value = '';
  });

  // -- old sessions ----------------------------------------------------------
  const old = document.getElementById('old');
  const oldList = document.getElementById('old-list');
  const oldSays = document.getElementById('old-says');

  async function loadOld() {
    try {
      const { ok, data } = await call('/api/sessions');
      if (!ok) { oldSays.textContent = "The Mac wouldn't list its sessions."; return; }
      oldList.replaceChildren(...data.sessions.map((session) => {
        const row = document.createElement('li');
        const said = document.createElement('span');
        said.textContent = session.title;
        const where = document.createElement('small');
        where.textContent = 'in ' + session.folder + ', ' + (ago(session.at) === 'now' ? 'just now' : ago(session.at) + ' ago');
        said.append(where);
        row.append(said);
        if (session.open) {
          const open = document.createElement('small');
          open.textContent = 'open';
          row.append(open);
        } else {
          const go = document.createElement('button');
          go.type = 'button';
          go.textContent = 'Resume';
          go.addEventListener('click', () => reopen(session, go));
          row.append(go);
        }
        return row;
      }));
      if (!data.sessions.length) oldSays.textContent = 'No sessions from the last few weeks on this Mac.';
    } catch (e) {
      oldSays.textContent = "Can't reach the Mac.";
    }
  }

  async function reopen(session, button) {
    button.disabled = true;
    button.textContent = 'Opening';
    try {
      const { data } = await call('/api/resume', { id: session.id });
      oldSays.textContent = data.sent
        ? session.title + ' is opening on the Mac. Its window shows up above in a few seconds.'
        : 'Not resumed: ' + (data.outcome || data.error || 'the Mac did not say why') + '.';
      if (data.sent) { setTimeout(refresh, 4000); setTimeout(loadOld, 8000); }
      else { button.disabled = false; button.textContent = 'Resume'; }
    } catch (e) {
      oldSays.textContent = "Not resumed: can't reach the Mac.";
      button.disabled = false;
      button.textContent = 'Resume';
    }
  }

  old.addEventListener('toggle', () => { if (old.open) loadOld(); });

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

  // One copy of the page at a time. Every push you tap opens another tab, and two of
  // them reading aloud at once is no use: the newest takes over, the others go quiet
  // and say so, and a tap on one of those takes it back.
  const tabs = 'BroadcastChannel' in window ? new BroadcastChannel('speakhud-page') : null;
  if (tabs) {
    tabs.onmessage = (e) => {
      if (!e.data || e.data.from === pageId || !active) return;
      active = false;
      line.length = 0;
      if (reading) hush('other-tab');
      trouble.textContent = 'This page is open in a newer tab. Tap here to use this one instead.';
      trouble.hidden = false;
    };
    tabs.postMessage({ from: pageId });
  }
  trouble.addEventListener('click', () => {
    if (active) return;
    active = true;
    say('');
    if (tabs) tabs.postMessage({ from: pageId });
    refresh();
  });

  window.addEventListener('hashchange', () => { wentTo = null; goToHash(); });
  // Leaving the page (another app, the lock button) stops a phone's voice anyway: keep
  // the place, so Resume carries on from there when you're back.
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) { line.length = 0; pause('hidden'); } else refresh();
  });
  setInterval(() => { if (!document.hidden) refresh(); }, POLL_MS);
  refresh();
})();
