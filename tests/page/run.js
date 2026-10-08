// What the phone page does, checked by running the real page (phone/app.js on the
// elements of phone/index.html) in the stand-in browser of browser.js. Each scenario is
// one visit: a fresh page, a fake Mac, a fake voice, and a clock moved by hand.
//   node tests/page/run.js            all of them
//   node tests/page/run.js stall      only those with "stall" in the name
'use strict';
const assert = require('assert');
const { makeWorld, turn, speaks, mute, hangs } = require('./browser.js');

const scenarios = [];
const scenario = (name, run) => scenarios.push({ name, run });
let opened = [];   // the pages a scenario opened: anything one of them threw fails it

// Open the page on a Mac that has these terminals.
async function open(turns, opts = {}) {
  const w = makeWorld(opts);
  w.mac.state.turns = turns;
  opened.push(w);
  await w.load();
  return w;
}
const readButton = (w, key) => w.win(key).querySelector('.win-read');
const answerBox = (w, key) => w.win(key).querySelector('.win-answer textarea');
// What the page told the Mac's log about its readings.
const heard = (w) => w.mac.posts('/api/heard').map((r) => r.body);
const SPEAK_ON = { storage: { speak: '1' } };   // the Read aloud switch, left on from a last visit
// The first tap of a visit, which is what lets a phone's page speak at all.
const firstTap = (w) => w.tap(w.document.body);

// -- windows -------------------------------------------------------------------

scenario('a window for each terminal, newest first, and a closed terminal\'s window goes', async () => {
  const w = await open([turn('a', 'Alpha.'), turn('b', 'Bee.')]);
  assert.deepStrictEqual(w.keys(), ['a', 'b']);
  assert.strictEqual(w.win('a').querySelector('.win-name').textContent, 'T-a');
  assert.strictEqual(w.win('a').querySelector('.win-text').textContent, 'Alpha.');
  assert.strictEqual(w.$('empty').hidden, true);
  assert.strictEqual(w.$('trouble').hidden, true);

  w.mac.state.turns = [turn('c', 'See.'), turn('b', 'Bee.')];
  await w.advance(2500);
  assert.deepStrictEqual(w.keys(), ['c', 'b']);

  w.mac.state.turns = [];
  await w.advance(2500);
  assert.deepStrictEqual(w.keys(), []);
  assert.strictEqual(w.$('empty').hidden, false);
});

scenario('an answer typed in the box goes to its terminal, and only what was sent is cleared', async () => {
  const w = await open([turn('a', 'Alpha.'), turn('b', 'Bee.')]);
  w.mac.routes['/api/reply'] = () => ({ data: { sent: true, outcome: 'sent' } });
  const box = answerBox(w, 'b');
  await w.type(box, 'yes please');
  await w.tap(w.win('b').querySelector('.win-answer button[type="submit"]'));
  assert.deepStrictEqual(w.mac.posts('/api/reply').map((r) => [r.body.key, r.body.text]), [['b', 'yes please']]);
  assert.strictEqual(box.value, '');

  w.mac.routes['/api/reply'] = () => ({ data: { sent: false, outcome: 'no prompt there' } });
  await w.type(box, 'again');
  await w.tap(w.win('b').querySelector('.win-answer button[type="submit"]'));
  assert.strictEqual(box.value, 'again');
  assert.strictEqual(w.win('b').querySelector('.win-note').textContent, 'Not sent: no prompt there.');
});

scenario('a question box shows its choices as buttons and takes the answer box away', async () => {
  const box = { ask: 'Which one?', tabs: null, hints: 'Enter to select', rows: [
    { label: 'First', detail: 'the safe one', number: 1, cursor: true, checked: null, types: false },
    { label: 'Second', detail: null, number: 2, cursor: false, checked: null, types: false },
    { label: 'Type something', detail: null, number: 3, cursor: false, checked: null, types: true }] };
  const w = await open([turn('a', 'Alpha.', { box })]);
  const el = w.win('a');
  assert.strictEqual(el.querySelector('.win-asks').hidden, false);
  assert.strictEqual(el.querySelector('.win-question').textContent, 'Which one?');
  assert.deepStrictEqual(el.querySelector('.win-options').children.map((c) => c.tagName), ['BUTTON', 'BUTTON', 'FORM']);
  assert.strictEqual(el.querySelector('.win-state').textContent, 'asking');
  assert.strictEqual(el.querySelector('.win-answer').hidden, true);
});

scenario('the status line reads model first, then context, and takes a colour as it fills', async () => {
  const w = await open([
    turn('a', 'Alpha.', { status: 'speakhud (main*) | Opus 5.5 ctx:51% used', context: 51 }),
    turn('b', 'Bee.', { status: 'a line of my own', context: null }),
  ]);
  const a = w.win('a').querySelector('.win-status');
  assert.strictEqual(a.textContent, 'Opus 5.5 · context 51% · speakhud (main*)');
  assert.strictEqual(a.classList.contains('is-half'), true);
  assert.strictEqual(w.win('b').querySelector('.win-status').textContent, 'a line of my own');
});

scenario('the Mac out of reach is said on the page, and unsaid once it answers again', async () => {
  const w = await open([turn('a', 'Alpha.')]);
  w.mac.down = true;
  await w.advance(2500);
  assert.strictEqual(w.$('trouble').hidden, false);
  assert.match(w.$('trouble').textContent, /^Can't reach the Mac\./);
  w.mac.down = false;
  await w.advance(2500);
  assert.strictEqual(w.$('trouble').hidden, true);
});

// -- reading aloud -------------------------------------------------------------

scenario('Read says who it is, then the turn a paragraph at a time, and tells the Mac how it went', async () => {
  const w = await open([turn('a', 'First paragraph.\n\n- Second one.')]);
  await w.tap(readButton(w, 'a'));
  assert.strictEqual(readButton(w, 'a').textContent, 'Pause');
  assert.strictEqual(w.win('a').querySelector('.win-reading').hidden, false);
  await w.advance(3000);
  assert.deepStrictEqual(w.voice.texts(), ['T-a.', 'First paragraph.', 'Second one.']);
  assert.strictEqual(readButton(w, 'a').textContent, 'Read');
  assert.strictEqual(w.win('a').querySelector('.win-reading').hidden, true);
  const told = heard(w);
  assert.strictEqual(told.length, 1);
  assert.deepStrictEqual([told[0].parts, told[0].end, told[0].why, told[0].stalls], [3, 'finished', 'tap', 0]);
});

scenario('Pause keeps the place and Resume goes on from the word it had reached', async () => {
  const w = await open([turn('a', 'one two three four five six.')], { manner: speaks({ perWord: 100 }) });
  await w.tap(readButton(w, 'a'));
  await w.advance(400);                       // the name, then as far as "three"
  await w.tap(readButton(w, 'a'));
  assert.strictEqual(readButton(w, 'a').textContent, 'Resume');
  assert.strictEqual(w.voice.speaking, false);
  await w.advance(5000);
  assert.deepStrictEqual(w.voice.texts(), ['T-a.', 'one two three four five six.']);   // nothing more by itself
  await w.tap(readButton(w, 'a'));
  await w.advance(2000);
  assert.deepStrictEqual(w.voice.texts().slice(2), ['three four five six.']);
  assert.strictEqual(readButton(w, 'a').textContent, 'Read');
  assert.deepStrictEqual(heard(w).map((h) => [h.why, h.end]), [['tap', 'paused'], ['resume', 'finished']]);
});

scenario('Stop ends a reading, and a tap on another window\'s Read replaces it', async () => {
  const w = await open([turn('a', 'Alpha one.\nAlpha two.'), turn('b', 'Bee.')]);
  await w.tap(readButton(w, 'a'));
  await w.advance(100);
  await w.tap(readButton(w, 'b'));
  assert.strictEqual(readButton(w, 'a').textContent, 'Read');
  assert.strictEqual(readButton(w, 'b').textContent, 'Pause');
  await w.advance(100);
  await w.tap(w.win('b').querySelector('.win-stop'));
  assert.strictEqual(readButton(w, 'b').textContent, 'Read');
  await w.advance(5000);
  assert.deepStrictEqual(w.voice.texts(), ['T-a.', 'T-b.']);
  assert.deepStrictEqual(heard(w).map((h) => h.end), ['replaced', 'stopped']);
});

scenario('with Read aloud on, a turn is read as it arrives, but only after a tap in this visit', async () => {
  const w = await open([turn('a', 'Alpha.'), turn('b', 'Bee.')], SPEAK_ON);
  assert.strictEqual(w.$('speak').checked, true);
  w.mac.state.turns = [turn('a', 'Alpha, a second turn.'), turn('b', 'Bee.')];
  await w.advance(2500);
  assert.deepStrictEqual(w.voice.texts(), []);          // a phone won't let a page speak before a tap

  await firstTap(w);
  w.mac.state.turns = [turn('b', 'Bee has finished.'), turn('a', 'Alpha, a second turn.')];
  await w.advance(4000);
  assert.deepStrictEqual(w.voice.texts().filter((t) => t.trim()), ['T-b.', 'Bee has finished.']);
  assert.deepStrictEqual(heard(w).map((h) => [h.why, h.end]), [['arrival', 'finished']]);
});

scenario('with Read aloud off, a turn that arrives is not read', async () => {
  const w = await open([turn('a', 'Alpha.')]);
  await firstTap(w);
  w.mac.state.turns = [turn('a', 'Alpha, a second turn.')];
  await w.advance(4000);
  assert.deepStrictEqual(w.voice.texts(), []);
});

scenario('turns that arrive during a reading wait their turn and are read after it', async () => {
  const w = await open([turn('a', 'Alpha.'), turn('b', 'Bee.')], Object.assign({ manner: speaks({ lasts: 1500 }) }, SPEAK_ON));
  await w.tap(readButton(w, 'a'));
  w.mac.state.turns = [turn('b', 'Bee has finished.'), turn('a', 'Alpha.')];
  await w.advance(2600);                      // b's turn lands while a is still being read
  assert.deepStrictEqual(w.voice.texts(), ['T-a.', 'Alpha.']);
  await w.advance(6000);
  assert.deepStrictEqual(w.voice.texts(), ['T-a.', 'Alpha.', 'T-b.', 'Bee has finished.']);
});

scenario('leaving the page pauses a reading, and Resume carries on when you are back', async () => {
  const w = await open([turn('a', 'one two three four five six.')], { manner: speaks({ perWord: 100 }) });
  await w.tap(readButton(w, 'a'));
  await w.advance(400);
  await w.leave();
  assert.strictEqual(w.voice.speaking, false);
  await w.comeBack();
  assert.strictEqual(readButton(w, 'a').textContent, 'Resume');
  await w.tap(readButton(w, 'a'));
  await w.advance(2000);
  assert.deepStrictEqual(w.voice.texts().slice(2), ['three four five six.']);
  assert.deepStrictEqual(heard(w).map((h) => h.end), ['hidden', 'finished']);
});

scenario('a voice that goes quiet mid-paragraph is picked up from the word it had reached', async () => {
  const w = await open([turn('a', 'one two three four five.')]);
  // Fine with everything but the paragraph, which it drops after "three" without a word.
  w.voice.manner = (u) => (u.text.startsWith('one') ? hangs({ words: 3 }) : speaks())(u);
  await w.tap(readButton(w, 'a'));
  await w.advance(3000);
  assert.deepStrictEqual(w.voice.texts(), ['T-a.', 'one two three four five.']);
  assert.strictEqual(readButton(w, 'a').textContent, 'Pause');
  await w.advance(3000);
  assert.deepStrictEqual(w.voice.texts(), ['T-a.', 'one two three four five.', 'three four five.']);
  assert.strictEqual(readButton(w, 'a').textContent, 'Read');
  assert.deepStrictEqual(heard(w).map((h) => [h.stalls, h.end]), [[1, 'finished']]);
});

scenario('the speed button steps the rate, and a reading picks up at the new rate from the same word', async () => {
  const w = await open([turn('a', 'one two three four five six.')], { manner: speaks({ perWord: 100 }) });
  await w.tap(readButton(w, 'a'));
  await w.advance(400);
  await w.tap(w.$('speed'));
  assert.strictEqual(w.$('speed').textContent, 'Speed 1.25×');
  assert.strictEqual(w.store.get('speed'), '1.25');
  const last = w.voice.said[w.voice.said.length - 1];
  assert.deepStrictEqual([last.text, last.rate], ['three four five six.', 1.25]);
  assert.strictEqual(readButton(w, 'a').textContent, 'Pause');
});

scenario('a paused reading whose window goes is forgotten: new turns are read and the page sorts again', async () => {
  const w = await open([turn('a', 'Alpha one.\nAlpha two.'), turn('b', 'Bee.')], SPEAK_ON);
  await w.tap(readButton(w, 'a'));
  await w.advance(100);
  await w.leave();                            // which pauses it, place kept
  w.mac.state.turns = [turn('b', 'Bee.')];    // and meanwhile terminal a is closed on the Mac
  await w.comeBack();
  assert.deepStrictEqual(w.keys(), ['b']);
  const before = w.voice.said.length;
  w.mac.state.turns = [turn('c', 'See, the newest.'), turn('b', 'Bee has a new turn.')];
  await w.advance(8000);
  assert.deepStrictEqual(w.voice.texts().slice(before), ['T-c.', 'See, the newest.', 'T-b.', 'Bee has a new turn.']);
  assert.deepStrictEqual(w.keys(), ['c', 'b']);
});

scenario('a reading stops when its window goes, and what waited behind it is read', async () => {
  const w = await open([turn('a', 'Alpha one.\nAlpha two.\nAlpha three.'), turn('b', 'Bee.')], Object.assign({ manner: speaks({ lasts: 2000 }) }, SPEAK_ON));
  await w.tap(readButton(w, 'a'));
  w.mac.state.turns = [turn('b', 'Bee has finished.'), turn('a', 'Alpha one.\nAlpha two.\nAlpha three.')];
  await w.advance(2600);                      // b's turn lands and waits behind a's
  w.mac.state.turns = [turn('b', 'Bee has finished.')];   // then terminal a is closed on the Mac, mid "Alpha two."
  await w.advance(2500);
  assert.deepStrictEqual(w.keys(), ['b']);
  assert.deepStrictEqual(heard(w).map((h) => h.end), ['closed']);
  await w.advance(9000);
  assert.deepStrictEqual(w.voice.texts(), ['T-a.', 'Alpha one.', 'Alpha two.', 'T-b.', 'Bee has finished.']);   // never "Alpha three."
  assert.strictEqual(readButton(w, 'b').textContent, 'Read');
});

// -- one tab at a time ---------------------------------------------------------

scenario('a newer tab takes over: this one stops reading and says so, and a tap takes it back', async () => {
  const w = await open([turn('a', 'Alpha one.\nAlpha two.')]);
  await w.tap(readButton(w, 'a'));
  await w.advance(100);
  await w.newerTab();
  assert.strictEqual(w.voice.speaking, false);
  assert.strictEqual(readButton(w, 'a').textContent, 'Read');
  assert.strictEqual(w.$('trouble').hidden, false);
  assert.match(w.$('trouble').textContent, /newer tab/);
  const polls = w.mac.gets('/api/state').length;
  await w.advance(10000);
  assert.strictEqual(w.mac.gets('/api/state').length, polls);   // it has stopped asking the Mac

  await w.tap(w.$('trouble'));
  assert.strictEqual(w.$('trouble').hidden, true);
  assert.strictEqual(w.mac.gets('/api/state').length, polls + 1);
  assert.strictEqual(w.channels[0].posted.length, 2);            // and has told the other tab so
});

// -- dictation -----------------------------------------------------------------

scenario('the mic by an answer box puts what the Mac heard in the box', async () => {
  const w = await open([turn('a', 'Alpha.')], { mic: true });
  w.mac.routes['/api/hear'] = () => ({ data: { text: 'hello there' } });
  const mic = w.win('a').querySelector('.win-mic');
  assert.strictEqual(mic.hidden, false);
  await w.tap(mic);
  assert.strictEqual(mic.classList.contains('is-listening'), true);
  await w.mic.loud(600);
  await w.tap(mic);                           // done talking
  await w.advance(500);
  assert.strictEqual(answerBox(w, 'a').value, 'hello there');
  assert.strictEqual(mic.classList.contains('is-listening'), false);
  assert.deepStrictEqual([w.mic.opened, w.mic.stopped], [1, 1]);
});

// -- run them ------------------------------------------------------------------

(async () => {
  const only = process.argv[2];
  const began = Date.now();
  let ran = 0;
  let failed = 0;
  for (const s of scenarios) {
    if (only && !s.name.includes(only)) continue;
    ran++;
    opened = [];
    try {
      await s.run();
      for (const w of opened) assert.deepStrictEqual(w.errors.map(String), [], 'the page threw');
    } catch (e) {
      failed++;
      console.log('FAILED: ' + s.name + '\n' + String((e && e.stack) || e).replace(/^/gm, '    '));
    }
  }
  console.log((ran - failed) + '/' + ran + ' page scenarios passed (' + (Date.now() - began) + ' ms)');
  process.exit(failed || !ran ? 1 : 0);
})();
