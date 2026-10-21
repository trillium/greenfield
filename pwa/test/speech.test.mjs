// concept: V1 (Dictate: the browser's recognizer fills the box; a clear message where there is none)
import test from 'node:test';
import assert from 'node:assert/strict';
import { Dictation, addPhrases, readResults, speechErrorMessage, speechSupport } from '../src/speech.js';

test('a browser with no recognizer says so, and says what still works', () => {
  const s = speechSupport({});
  assert.equal(s.supported, false);
  assert.match(s.reason, /cannot turn speech into text/);
  assert.match(s.reason, /type into the box/);
});

test('Safari\'s prefixed recognizer is found, and a page that is not secure is refused with the reason', () => {
  class R {}
  assert.equal(speechSupport({ webkitSpeechRecognition: R, isSecureContext: true }).Recognition, R);
  assert.equal(speechSupport({ SpeechRecognition: R }).supported, true);
  const insecure = speechSupport({ webkitSpeechRecognition: R, isSecureContext: false });
  assert.equal(insecure.supported, false);
  assert.match(insecure.reason, /https/);
});

test('errors have words and a next step', () => {
  assert.match(speechErrorMessage('not-allowed'), /Allow it/);
  assert.match(speechErrorMessage('network'), /internet/);
  assert.match(speechErrorMessage('audio-capture'), /microphone/);
  assert.match(speechErrorMessage('weird'), /weird/);
});

const result = (transcript, isFinal) => Object.assign([{ transcript }], { isFinal });

test('finished phrases and the one still being heard are told apart', () => {
  const results = [result(' hello ', true), result('wor', false), result('ld', false)];
  assert.deepEqual(readResults(results, 0), { finals: ['hello'], interim: 'wor ld' });
  assert.deepEqual(readResults(results, 1), { finals: [], interim: 'wor ld' });
  assert.deepEqual(readResults([result('', true)], 0), { finals: [], interim: '' });
});

test('phrases land at the end of the box with the phone\'s spacing', () => {
  assert.equal(addPhrases('', ['hello', 'world']), 'hello world');
  assert.equal(addPhrases('line one\n', ['next']), 'line one\nnext');
});

class FakeRecognition {
  static instances = [];
  constructor() { FakeRecognition.instances.push(this); this.started = 0; this.stopped = 0; }
  start() { this.started += 1; this.onstart?.(); }
  stop() { this.stopped += 1; this.onend?.(); }
}

function harness(now = () => 0) {
  FakeRecognition.instances = [];
  const log = { phrases: [], interim: [], states: [], errors: [] };
  const on = { phrase: (p) => log.phrases.push(p), interim: (t) => log.interim.push(t), state: (s) => log.states.push(s), error: (e) => log.errors.push(e) };
  return { log, dictation: new Dictation(FakeRecognition, on, { now }), last: () => FakeRecognition.instances.at(-1) };
}

test('tap to start listens, finished phrases arrive, tap to stop ends it', () => {
  const { log, dictation, last } = harness();
  dictation.start();
  assert.equal(last().continuous, true);
  assert.equal(last().interimResults, true);
  last().onresult({ resultIndex: 0, results: [result('send the report', true)] });
  assert.deepEqual(log.phrases, ['send the report']);
  dictation.stop();
  assert.equal(dictation.listening, false);
  assert.equal(log.states.at(-1), 'idle');
});

test('a recognizer that ends by itself after a pause is started again while dictation is wanted', () => {
  let t = 0;
  const { dictation, last } = harness(() => t);
  dictation.start();
  t = 5000;
  last().onend();
  assert.equal(FakeRecognition.instances.length, 2);
  assert.equal(dictation.listening, true);
});

test('one that stops at once does not loop', () => {
  const { dictation, log } = harness(() => 0);
  dictation.start();
  FakeRecognition.instances[0].onend();
  assert.equal(FakeRecognition.instances.length, 1);
  assert.equal(dictation.listening, false);
  assert.equal(log.states.at(-1), 'idle');
});

test('a refused microphone stops dictation with the reason', () => {
  const { dictation, log, last } = harness();
  dictation.start();
  last().onerror({ error: 'not-allowed' });
  assert.equal(dictation.listening, false);
  assert.match(log.errors[0], /Microphone or speech access is off/);
  last().onend();
  assert.equal(FakeRecognition.instances.length, 1);
});

test('silence is not an error', () => {
  const { dictation, log, last } = harness();
  dictation.start();
  last().onerror({ error: 'no-speech' });
  assert.deepEqual(log.errors, []);
  assert.equal(dictation.listening, true);
});
