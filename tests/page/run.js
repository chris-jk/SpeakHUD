// What the phone page does, checked by running the real page (phone/app.js on the
// elements of phone/index.html) in the stand-in browser of browser.js. Each scenario is
// one visit: a fresh page, a fake Mac, a fake voice, and a clock moved by hand.
//   node tests/page/run.js            all of them
//   node tests/page/run.js stall      only those with "stall" in the name
'use strict';
const assert = require('assert');
const { makeWorld, makeClock, makeVoice, Utterance, turn, speaks, mute, hangs } = require('./browser.js');

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

scenario('an own answer half typed is kept when only the box\'s cursor or hints change', async () => {
  const box = (cursorAt, hints, first = 'First') => ({ ask: 'Which one?', tabs: null, hints, rows: [
    { label: first, detail: null, number: 1, cursor: cursorAt === 0, checked: null, types: false },
    { label: 'Type something', detail: null, number: 2, cursor: cursorAt === 1, checked: null, types: true }] });
  const other = turn('b', 'Bee.', { box: box(0, 'Enter to select') });
  const w = await open([turn('a', 'Alpha.', { box: box(0, 'Enter to select') }), other]);
  const field = w.win('a').querySelector('.win-options input');
  await w.type(field, 'my half-typed own answer');
  w.mac.state.turns = [turn('a', 'Alpha.', { box: box(1, 'Enter to select') }), other];   // the cursor moved
  await w.advance(2500);
  w.mac.state.turns = [turn('a', 'Alpha.', { box: box(1, 'Esc to cancel') }), other];     // the hints changed
  await w.advance(2500);
  assert.ok(w.win('a').querySelector('.win-options input') === field, 'the own-answer field was rebuilt, and what was typed in it is gone');
  assert.strictEqual(field.value, 'my half-typed own answer');
  const looks = w.mac.gets('/api/screen').length;
  await w.advance(5000);
  assert.strictEqual(w.mac.gets('/api/screen').length, looks + 4);   // each asking window's screen is looked at once a poll, no more

  w.mac.state.turns = [turn('a', 'Alpha.', { box: box(1, 'Esc to cancel', 'Another choice') }), other];   // a choice changed
  await w.advance(2500);
  assert.strictEqual(w.win('a').querySelector('.win-options button').textContent, '1Another choice');
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

scenario('the status line puts the model first however the Mac\'s line is cut into pieces', async () => {
  const lines = [
    ['speakhud (main*) | Opus 5.5 | ctx:51% used', 'Opus 5.5 · context 51% · speakhud (main*)'],   // the model in a piece of its own
    ['speakhud (main*) | Opus 5.5 ctx:51% used', 'Opus 5.5 · context 51% · speakhud (main*)'],     // or beside the context
    ['ctx:51% used | speakhud (main*) | Sonnet 4.5', 'Sonnet 4.5 · context 51% · speakhud (main*)'],
    ['speakhud ctx:51% | Opus 5.5', 'Opus 5.5 · context 51% · speakhud'],
    ['speakhud (main*) | ctx:51% used', 'context 51% · speakhud (main*)'],   // no model to tell apart
    ['notes ctx:51% | zsh', 'notes · context 51% · zsh'],               // nor here: what sits by the context leads, as before
  ];
  const w = await open(lines.map(([status], i) => turn('t' + i, 'Text.', { status, context: 51 })));
  assert.deepStrictEqual(lines.map((line, i) => w.win('t' + i).querySelector('.win-status').textContent), lines.map((line) => line[1]));
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

scenario('a link the page cannot read is not called a lost Mac, and the page goes on working', async () => {
  const w = await open([turn('a', 'Alpha.'), turn('b', 'Bee.')], Object.assign({ hash: '#%E0%A4%A', mic: true }, SPEAK_ON));
  assert.deepStrictEqual(w.keys(), ['a', 'b']);
  assert.strictEqual(w.$('trouble').hidden, true);
  assert.strictEqual(w.win('a').querySelector('.win-mic').hidden, false);   // the draw got to its end
  await firstTap(w);
  w.mac.state.turns = [turn('a', 'Alpha, a second turn.'), turn('b', 'Bee.')];
  await w.advance(4000);
  assert.deepStrictEqual(w.voice.texts().filter((t) => t.trim()), ['T-a.', 'Alpha, a second turn.']);   // and news is still news
});

scenario('one turn the page cannot draw is said as the page\'s own fault, and the others are drawn', async () => {
  const w = await open([turn('a', 'Alpha.', { box: { ask: 'Pick one', tabs: null, hints: null } }), turn('b', 'Bee.')]);
  assert.deepStrictEqual(w.keys(), ['a', 'b']);
  assert.strictEqual(w.win('b').querySelector('.win-text').textContent, 'Bee.');
  assert.strictEqual(w.win('b').querySelector('.win-read').hidden, false);
  assert.strictEqual(w.$('trouble').hidden, false);
  assert.doesNotMatch(w.$('trouble').textContent, /reach the Mac/);
  assert.match(w.$('trouble').textContent, /T-a/);
  assert.strictEqual(w.logged.length, 1);       // and it's left where a debugger can see it
  await w.tap(readButton(w, 'a'));              // reading it doesn't trip either
  await w.advance(3000);
  assert.deepStrictEqual(w.voice.texts(), ['T-a.', 'Alpha.', 'It is asking.', 'Pick one']);
});

scenario('a fault in the drawing after an answer has gone is not called a failure to send', async () => {
  const w = await open([turn('a', 'Alpha.')]);
  w.mac.routes['/api/reply'] = () => ({ data: { sent: true, outcome: 'sent', state: { away: false, quick: [], turns: [null] } } });
  await w.type(answerBox(w, 'a'), 'yes');
  await w.tap(w.win('a').querySelector('.win-answer button[type="submit"]'));
  assert.strictEqual(w.win('a').querySelector('.win-note').textContent, '');
  assert.strictEqual(answerBox(w, 'a').value, '');
  assert.doesNotMatch(w.$('trouble').textContent, /reach the Mac/);
  assert.strictEqual(w.$('trouble').hidden, false);
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

scenario('a word the voice reports late does not move the place back', async () => {
  const w = await open([turn('a', 'one two three four five six.')], { manner: speaks({ perWord: 100 }) });
  await w.tap(readButton(w, 'a'));
  await w.advance(400);                       // as far as "three"
  w.voice.said[1].onboundary({ name: 'word', charIndex: 4, charLength: 3 });   // "two", said again late
  await w.tap(readButton(w, 'a'));            // Pause
  await w.tap(readButton(w, 'a'));            // Resume
  assert.deepStrictEqual(w.voice.texts().slice(2), ['three four five six.']);
  assert.deepStrictEqual(heard(w).map((h) => [h.words, h.backwards, h.end]), [[5, 1, 'paused']]);   // the name, three words, the late one
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

scenario('the Read aloud switch says so when it goes on, is remembered, and off stops the voice', async () => {
  const w = await open([turn('a', 'Alpha.')], { manner: speaks({ lasts: 1500 }) });
  const says = w.$('speak-says');
  assert.strictEqual(says.hidden, true);
  await w.tap(w.$('speak'));
  assert.deepStrictEqual(w.voice.texts(), ['Reading aloud.']);
  assert.strictEqual(w.store.get('speak'), '1');
  assert.deepStrictEqual([says.hidden, says.textContent], [false, 'This phone reads new turns aloud while this page is open.']);
  w.mac.state.turns = [turn('a', 'Alpha, a second turn.')];
  await w.advance(3000);                      // read as it arrives, and still being read when:
  assert.strictEqual(readButton(w, 'a').textContent, 'Pause');
  await w.tap(w.$('speak'));
  assert.strictEqual(w.voice.speaking, false);
  assert.strictEqual(readButton(w, 'a').textContent, 'Read');
  assert.strictEqual(w.store.get('speak'), '0');
  assert.deepStrictEqual(heard(w).map((h) => [h.why, h.end]), [['arrival', 'off']]);
});

scenario('a push brings you to a window: the first tap of the visit reads that one, question and all', async () => {
  const w = await open([turn('a', 'Alpha.'), turn('b', 'Bee.', { question: 'Shall I go on?' })], Object.assign({ hash: '#b' }, SPEAK_ON));
  assert.deepStrictEqual(w.scrolledTo, ['b']);
  assert.strictEqual(w.$('speak-says').textContent, 'Tap anywhere once and this phone will read new turns aloud.');
  await firstTap(w);
  await w.advance(3000);
  assert.deepStrictEqual(w.voice.texts().filter((t) => t.trim()), ['T-b.', 'Bee.', 'It is asking.', 'Shall I go on?']);
  assert.deepStrictEqual(heard(w).map((h) => [h.why, h.end]), [['visit', 'finished']]);
});

scenario('a turn that changes while it is being read is dropped, and the new one read in its place', async () => {
  const w = await open([turn('a', 'Old words, first.\nOld words, second.')], Object.assign({ manner: speaks({ lasts: 2000 }) }, SPEAK_ON));
  await w.tap(readButton(w, 'a'));
  w.mac.state.turns = [turn('a', 'New words.')];
  await w.advance(2500);                      // the name is said, "Old words, first." is under way
  await w.advance(9000);
  assert.deepStrictEqual(w.voice.texts(), ['T-a.', 'Old words, first.', 'T-a.', 'New words.']);
  assert.deepStrictEqual(heard(w).map((h) => [h.why, h.end]), [['tap', 'changed'], ['arrival', 'finished']]);
});

scenario('a voice picked from the list says who it is, and a reading carries on in it from the same word', async () => {
  const voices = [
    { name: 'Samantha', lang: 'en-US', voiceURI: 'com.apple.voice.Samantha' },
    { name: 'Daniel (Enhanced)', lang: 'en-GB', voiceURI: 'com.apple.voice.Daniel' },
    { name: 'Amelie', lang: 'fr-CA', voiceURI: 'com.apple.voice.Amelie' },
  ];
  const w = await open([turn('a', 'one two three four five six.')], { voices, manner: speaks({ perWord: 100 }) });
  const list = w.$('voice');
  assert.strictEqual(w.$('voice-pick').hidden, false);
  assert.deepStrictEqual(list.children.map((o) => o.textContent), ["Phone's own", 'Samantha', 'Daniel (Enhanced) (en-GB)']);   // its own language only
  const pick = async (uri) => { list.value = uri; list.dispatchEvent({ type: 'change', bubbles: true }); await w.settle(); };

  await pick('com.apple.voice.Daniel');
  assert.strictEqual(w.store.get('voice'), 'com.apple.voice.Daniel');
  assert.deepStrictEqual(w.voice.said.map((u) => [u.text, u.voice && u.voice.name]), [['This is Daniel.', 'Daniel (Enhanced)']]);
  await w.advance(1000);

  await w.tap(readButton(w, 'a'));
  await w.advance(400);                       // the name, then as far as "three"
  await pick('com.apple.voice.Samantha');
  const last = w.voice.said[w.voice.said.length - 1];
  assert.deepStrictEqual([last.text, last.voice.name, last.lang], ['three four five six.', 'Samantha', 'en-US']);
  await w.advance(2000);
  assert.deepStrictEqual(heard(w).map((h) => [h.voice, h.end]), [['Daniel (Enhanced)', 'finished']]);   // one reading, begun in Daniel
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

scenario('Stop in the moment a stalled voice is being picked up again stops it, and nothing trips', async () => {
  const w = await open([turn('a', 'one two three four five.')], { manner: hangs({ words: 1 }) });
  await w.tap(readButton(w, 'a'));
  for (let i = 0; i < 400 && !w.voice.cancels; i++) await w.advance(50);   // until the stall is noticed
  assert.strictEqual(w.voice.cancels, 1);
  const handed = w.voice.said.length;
  await w.tap(w.win('a').querySelector('.win-stop'));                       // inside the 120 ms before it's picked up
  await w.advance(500);
  assert.deepStrictEqual(w.errors.map(String), []);
  assert.strictEqual(w.voice.said.length, handed);
  assert.strictEqual(readButton(w, 'a').textContent, 'Read');
});

scenario('a voice that never starts gives up, and the Mac\'s log is told', async () => {
  const w = await open([turn('a', 'Alpha one.\nAlpha two.')], { manner: mute() });
  await w.tap(readButton(w, 'a'));
  assert.strictEqual(readButton(w, 'a').textContent, 'Pause');
  await w.advance(30000);
  assert.strictEqual(readButton(w, 'a').textContent, 'Read');
  const told = heard(w);
  assert.strictEqual(told.length, 1);
  assert.deepStrictEqual([told[0].parts, told[0].words, told[0].end, told[0].stalls > 0], [0, 0, 'stalled', true]);
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

scenario('nothing is read into an open mic: a turn that arrives is read when the mic closes', async () => {
  const w = await open([turn('a', 'Alpha.'), turn('b', 'Bee.')], Object.assign({ mic: true }, SPEAK_ON));
  w.mac.routes['/api/hear'] = () => ({ data: { text: 'hello there' } });
  await firstTap(w);
  const before = w.voice.said.length;
  const mic = w.win('a').querySelector('.win-mic');
  await w.tap(mic);
  w.mac.state.turns = [turn('b', 'Bee has finished.'), turn('a', 'Alpha.')];
  await w.mic.loud(4000);                     // four seconds of talking; b's turn lands meanwhile
  assert.strictEqual(mic.classList.contains('is-listening'), true);
  assert.deepStrictEqual(w.voice.texts().slice(before), []);
  await w.tap(mic);                           // done talking
  await w.advance(3000);
  assert.strictEqual(answerBox(w, 'a').value, 'hello there');
  assert.deepStrictEqual(w.voice.texts().slice(before), ['T-b.', 'Bee has finished.']);
});

scenario('a reading the mic cuts into carries on from its word when the mic closes, then what arrived is read', async () => {
  const w = await open([turn('a', 'one two three four five six.'), turn('b', 'Bee.')],
    Object.assign({ mic: true, manner: speaks({ perWord: 100 }) }, SPEAK_ON));
  w.mac.routes['/api/hear'] = () => ({ data: { text: 'hello there' } });
  await w.tap(readButton(w, 'a'));
  await w.advance(400);                       // the name, then as far as "three"
  const mic = w.win('b').querySelector('.win-mic');
  await w.tap(mic);
  assert.strictEqual(w.voice.speaking, false);
  assert.strictEqual(readButton(w, 'a').textContent, 'Resume');
  w.mac.state.turns = [turn('c', 'See.'), turn('a', 'one two three four five six.'), turn('b', 'Bee.')];
  await w.mic.loud(3000);                     // a new terminal's turn lands while the mic is open
  assert.deepStrictEqual(w.voice.texts(), ['T-a.', 'one two three four five six.']);
  await w.tap(mic);
  await w.advance(6000);
  assert.deepStrictEqual(w.voice.texts().slice(2), ['three four five six.', 'T-c.', 'See.']);
  assert.deepStrictEqual(heard(w).map((h) => [h.why, h.end]), [['tap', 'mic'], ['resume', 'finished'], ['arrival', 'finished']]);
});

scenario('a mic that closes on a page you have left starts nothing: the reading it cut into stays paused', async () => {
  const w = await open([turn('a', 'one two three four five six.'), turn('b', 'Bee.')],
    Object.assign({ mic: true, manner: speaks({ perWord: 100 }) }, SPEAK_ON));
  await w.tap(readButton(w, 'a'));
  await w.advance(400);
  await w.tap(w.win('b').querySelector('.win-mic'));
  await w.leave();                            // the dictation sends what it has and lets the mic go
  await w.advance(1000);
  await w.comeBack();
  await w.advance(5000);
  assert.strictEqual(readButton(w, 'a').textContent, 'Resume');
  assert.deepStrictEqual(w.voice.texts(), ['T-a.', 'one two three four five six.']);
});

scenario('a pause of your own stays yours: a mic opening and closing does not end it', async () => {
  const w = await open([turn('a', 'one two three four five six.'), turn('b', 'Bee.')], { mic: true, manner: speaks({ perWord: 100 }) });
  await w.tap(readButton(w, 'a'));
  await w.advance(400);
  await w.tap(readButton(w, 'a'));            // Pause
  const mic = w.win('b').querySelector('.win-mic');
  await w.tap(mic);
  await w.mic.loud(1000);
  await w.tap(mic);
  await w.advance(6000);
  assert.strictEqual(readButton(w, 'a').textContent, 'Resume');
  assert.deepStrictEqual(w.voice.texts(), ['T-a.', 'one two three four five six.']);
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

scenario('the newer-tab notice outlasts a poll that was already on its way', async () => {
  const w = await open([turn('a', 'Alpha.')]);
  const line = w.mac.hold('/api/state');
  await w.advance(2500);                      // the next poll leaves, and hangs on the line
  assert.strictEqual(line.waiting.length, 1);
  await w.newerTab();
  line.release();
  await w.settle();
  assert.strictEqual(w.$('trouble').hidden, false);
  assert.match(w.$('trouble').textContent, /newer tab/);
});

scenario('an old tab does nothing, and looks it, until a tap on its notice takes it back', async () => {
  const w = await open([turn('a', 'Alpha.')], SPEAK_ON);
  w.mac.routes['/api/reply'] = () => ({ data: { sent: true, outcome: 'sent' } });
  const html = w.document.documentElement;
  await w.newerTab();
  assert.strictEqual(html.classList.contains('is-old'), true);

  await w.tap(readButton(w, 'a'));
  await w.advance(1000);
  assert.deepStrictEqual(w.voice.texts(), []);                   // it doesn't speak
  await w.type(answerBox(w, 'a'), 'sent from the old tab');
  await w.tap(w.win('a').querySelector('.win-answer button[type="submit"]'));
  w.win('a').querySelector('.win-answer').requestSubmit();       // Enter on a keyboard
  await w.tap(w.$('away'));
  await w.settle();
  assert.deepStrictEqual(w.mac.requests.filter((r) => r.method === 'POST').map((r) => r.path), []);   // or send anything
  assert.strictEqual(w.$('away').checked, false);
  assert.strictEqual(w.$('trouble').hidden, false);

  await w.tap(w.$('trouble'));
  assert.strictEqual(html.classList.contains('is-old'), false);
  assert.strictEqual(w.$('trouble').hidden, true);
  await w.tap(readButton(w, 'a'));
  await w.advance(1000);
  assert.deepStrictEqual(w.voice.texts().filter((t) => t.trim()), ['T-a.', 'Alpha.']);
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

// -- the Reader by itself ------------------------------------------------------
// The page's Reader, made again with nothing of the page around it: a voice and a clock
// of the test's own in place of the phone's, and for a page a table of what to say.
// What the scenarios above check through taps and polls, these check through the
// Reader's own calls.

async function rig(opts = {}) {
  const base = await open([]);                // only to be handed the page's own Reader
  const errors = [];
  opened.push({ errors });
  const caught = (e) => errors.push(e);
  const clock = makeClock({ caught });
  const voice = opts.noVoice ? undefined : makeVoice(clock, { caught, manner: opts.manner });
  const r = { clock, voice, hidden: false, says: opts.says || {}, drawn: [], reports: [] };
  r.reader = base.Reader({
    voice, Utterance, clock,
    page: {
      parts: (key) => (r.says[key] ? [{ say: key + '.' }].concat(r.says[key].map((say) => ({ say }))) : null),
      hidden: () => r.hidden,
      started: (part) => r.drawn.push(part.say),
      word: (part, index) => r.drawn.push(index),
      cleared: () => r.drawn.push('clear'),
      changed: () => {},
    },
    report: (told) => r.reports.push(told),
    lang: 'en-US', speed: 1, aloud: !!opts.aloud,
  });
  r.state = () => ({ ...r.reader.state() });
  r.spoken = () => voice.texts().filter((t) => t.trim());   // without the silent word that lets a page speak
  return r;
}
const ARRIVAL = ['turn', 'arrival'];

scenario('Reader: reads a window part by part, with a voice and a clock that are not the phone\'s', async () => {
  const r = await rig({ says: { a: ['First.', 'Second.'] }, manner: speaks({ perWord: 100 }) });
  r.reader.read('a');
  assert.deepStrictEqual(r.state(), { reading: 'a', paused: null, aloud: false, unlocked: true, speed: 1 });
  await r.clock.advance(3000);
  assert.deepStrictEqual(r.voice.texts(), ['a.', 'First.', 'Second.']);
  assert.deepStrictEqual(r.drawn, ['clear', 'a.', 0, 'First.', 0, 'Second.', 0, 'clear']);
  assert.deepStrictEqual(r.reports.map((t) => [t.parts, t.words, t.end, t.why, t.speed, t.voice]), [[3, 3, 'finished', 'tap', 1, 'own']]);
  assert.strictEqual(r.state().reading, null);
});

scenario('Reader: the page hears of each word as the voice gets to it, and of nothing from a reading that was stopped', async () => {
  const r = await rig({ says: { a: ['one two three.'] }, manner: speaks({ perWord: 100 }) });
  r.reader.read('a');
  await r.clock.advance(300);                 // the name, then "one", "two"
  assert.deepStrictEqual(r.drawn, ['clear', 'a.', 0, 'one two three.', 0, 4]);
  const dropped = r.voice.said[1];
  r.reader.stop();
  dropped.onboundary({ name: 'word', charIndex: 8, charLength: 5 });   // a phone can still report on what it was told to drop
  dropped.onend({});
  await r.clock.advance(1000);
  assert.deepStrictEqual(r.drawn, ['clear', 'a.', 0, 'one two three.', 0, 4, 'clear']);
  assert.deepStrictEqual(r.voice.texts(), ['a.', 'one two three.']);
});

scenario('Reader: turns are read as they arrive only with the switch on, after a tap, on a page someone is looking at', async () => {
  const r = await rig({ says: { a: ['Alpha.'], b: ['Bee.'], c: ['See.'] }, aloud: true });
  r.reader.arrived('a', ...ARRIVAL);          // no tap yet in this visit
  assert.strictEqual(r.reader.tapped(), true);
  assert.strictEqual(r.reader.tapped(), false);   // only the first is news
  r.hidden = true;
  r.reader.arrived('a', ...ARRIVAL);          // nobody is looking
  r.hidden = false;
  await r.clock.advance(1000);
  assert.deepStrictEqual(r.spoken(), []);

  r.reader.arrived('a', ...ARRIVAL);
  r.reader.arrived('b', ...ARRIVAL);
  r.reader.arrived('b', ...ARRIVAL);          // told of twice, it waits once
  r.reader.arrived('c', ...ARRIVAL);
  await r.clock.advance(5000);
  assert.deepStrictEqual(r.spoken(), ['a.', 'Alpha.', 'b.', 'Bee.', 'c.', 'See.']);

  r.reader.setAloud(false);
  r.reader.arrived('a', ...ARRIVAL);
  await r.clock.advance(1000);
  assert.strictEqual(r.spoken().length, 6);
});

scenario('Reader: Stop also drops what was waiting, and nothing is read over a pause of your own', async () => {
  const r = await rig({ says: { a: ['one two three four.'], b: ['Bee.'], c: ['See.'] }, aloud: true, manner: speaks({ perWord: 100 }) });
  r.reader.read('a');
  r.reader.arrived('b', ...ARRIVAL);          // waits behind a
  await r.clock.advance(300);
  r.reader.stop();
  assert.strictEqual(r.state().reading, null);
  await r.clock.advance(5000);
  r.reader.arrived('c', ...ARRIVAL);          // the next thing to be read is not followed by what Stop dropped
  await r.clock.advance(5000);
  assert.deepStrictEqual(r.voice.texts(), ['a.', 'one two three four.', 'c.', 'See.']);

  r.reader.read('a');
  await r.clock.advance(300);                 // as far as "two"
  r.reader.pause();
  assert.strictEqual(r.state().paused, 'a');
  r.reader.arrived('b', ...ARRIVAL);          // not read over the pause, and not kept for later
  await r.clock.advance(5000);
  r.reader.resume();
  await r.clock.advance(5000);
  assert.deepStrictEqual(r.voice.texts().slice(4), ['a.', 'one two three four.', 'two three four.']);
  assert.deepStrictEqual(r.reports.map((t) => t.end), ['stopped', 'finished', 'paused', 'finished']);
});

scenario('Reader: leaving the page keeps the place and lets go of what was waiting', async () => {
  const r = await rig({ says: { a: ['one two three four.'], b: ['Bee.'] }, aloud: true, manner: speaks({ perWord: 100 }) });
  r.reader.read('a');
  r.reader.arrived('b', ...ARRIVAL);          // waits behind a
  await r.clock.advance(300);                 // as far as "two"
  r.hidden = true;
  r.reader.left();
  assert.deepStrictEqual([r.state().reading, r.state().paused, r.voice.speaking], [null, 'a', false]);
  r.hidden = false;
  r.reader.resume();
  await r.clock.advance(5000);
  assert.deepStrictEqual(r.voice.texts(), ['a.', 'one two three four.', 'two three four.']);
  assert.deepStrictEqual(r.reports.map((t) => t.end), ['hidden', 'finished']);
});

scenario('Reader: a new speed or voice is heard at once from the same word, and is one reading in the log', async () => {
  const r = await rig({ says: { a: ['one two three four five six.'] }, manner: speaks({ perWord: 100 }) });
  const daniel = { name: 'Daniel (Enhanced)', lang: 'en-GB', voiceURI: 'daniel' };
  const last = () => r.voice.said[r.voice.said.length - 1];
  r.reader.setVoice(daniel);                  // as remembered from a last visit: nothing is said
  assert.deepStrictEqual(r.voice.texts(), []);
  r.reader.read('a');
  await r.clock.advance(400);                 // as far as "three"
  r.reader.setSpeed(1.5);
  assert.deepStrictEqual([last().text, last().rate, last().voice.name, last().lang], ['three four five six.', 1.5, 'Daniel (Enhanced)', 'en-GB']);
  await r.clock.advance(150);                 // on to "four"
  r.reader.setVoice(null, true);
  assert.deepStrictEqual([last().text, last().rate, last().voice, last().lang], ['four five six.', 1.5, undefined, 'en-US']);
  await r.clock.advance(3000);
  assert.deepStrictEqual(r.reports.map((t) => [t.why, t.end, t.speed, t.voice]), [['tap', 'finished', 1, 'Daniel (Enhanced)']]);

  r.reader.setVoice(daniel, true);            // with nothing being read, it says who it is
  assert.strictEqual(last().text, 'This is Daniel.');
});

scenario('Reader: with no voice to speak with, it reads nothing and nothing trips', async () => {
  const r = await rig({ says: { a: ['Alpha.'] }, aloud: true, noVoice: true });
  assert.strictEqual(r.reader.tapped(), false);
  r.reader.read('a');
  r.reader.arrived('a', ...ARRIVAL);
  r.reader.setAloud(true);
  r.reader.setVoice(null, true);
  r.reader.setSpeed(2);
  r.reader.micOpened();
  r.reader.micClosed();
  r.reader.pause();
  r.reader.resume();
  r.reader.left();
  r.reader.textChanged('a');
  r.reader.windowGone('a');
  r.reader.stop();
  await r.clock.advance(5000);
  assert.deepStrictEqual([r.state().reading, r.state().paused, r.reports.length], [null, null, 0]);
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
