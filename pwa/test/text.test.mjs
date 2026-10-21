// concept: V1 (the text box a dictation lands in) and V2 (what Submit sends)
import test from 'node:test';
import assert from 'node:assert/strict';
import { MARKER, displayed, forSending, isSendable, joining, normalizeNewlines, segments, spoken, trimEdges } from '../src/text.js';

test('the marker is the return arrow, and it is never part of what is sent', () => {
  assert.equal(MARKER, '↵');
  assert.ok(!forSending('one\ntwo').includes(MARKER));
});

test('every kind of line ending is one line feed', () => {
  assert.equal(normalizeNewlines('a\r\nb\rc\u2028d\u2029e\u0085f\ng'), 'a\nb\nc\nd\ne\nf\ng');
});

test('line breaks, empty lines and a trailing newline are kept; spaces and tabs at the ends are not', () => {
  assert.equal(forSending('  hello\n\nworld\n \t'), 'hello\n\nworld\n');
  assert.equal(forSending('\tx  '), 'x');
  assert.equal(trimEdges('  x  '), 'x');
});

test('a box of only spaces and line breaks sends nothing', () => {
  assert.equal(isSendable(' \n\t \n'), false);
  assert.equal(isSendable(''), false);
  assert.equal(isSendable(' a '), true);
});

test('more dictated words join with a space, none after a space or a line break', () => {
  assert.equal(joining('', 'hello'), 'hello');
  assert.equal(joining('hello', 'world'), 'hello world');
  assert.equal(joining('hello ', 'world'), 'hello world');
  assert.equal(joining('hello\n', 'world'), 'hello\nworld');
});

test('the box draws a marker before each line break and the text is unchanged', () => {
  const parts = segments('one\ntwo\n');
  assert.deepEqual(parts, [{ text: 'one' }, { marker: MARKER }, { text: '\n' }, { text: 'two' }, { marker: MARKER }, { text: '\n' }]);
  assert.equal(parts.filter((p) => p.text).map((p) => p.text).join(''), 'one\ntwo\n');
  assert.equal(displayed('a\r\nb'), `a${MARKER}\nb`);
  assert.deepEqual(segments(''), []);
  assert.deepEqual(segments('\n\n').filter((p) => p.marker).length, 2);
});

test('a screen reader hears a line break as "new line"', () => {
  assert.equal(spoken('one\ntwo'), 'one, new line, two');
  assert.equal(spoken('one\n\ntwo'), 'one, new line, new line, two');
});
