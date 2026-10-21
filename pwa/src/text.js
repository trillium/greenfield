// How the text box is read, joined and sent: the same rules as the phone app (App/Sources/Dictation/DictationText.swift).
// Line breaks are part of the text: they go to the computer as line feeds, which the helper types as Return key presses. Empty
// lines and a trailing newline are kept; only spaces and tabs at the two ends are dropped.

/** Drawn at each line break so it can be seen. Display only: never a character of the text, never sent. */
export const MARKER = '↵';

const NEWLINES = /\r\n|[\n\v\f\r\u0085\u2028\u2029]/g;
const EDGES = /^[\p{Zs}\t]+|[\p{Zs}\t]+$/gu;

/** CRLF, a lone CR and the Unicode line and paragraph separators as one line feed. */
export function normalizeNewlines(text) {
  return text.replace(NEWLINES, '\n');
}

/** Spaces and tabs off both ends; line breaks stay. */
export function trimEdges(text) {
  return text.replace(EDGES, '');
}

/** What a submit sends. */
export function forSending(text) {
  return trimEdges(normalizeNewlines(text));
}

/** Something to send: at least one visible character. A box of only spaces and line breaks sends nothing. */
export function isSendable(text) {
  return /\S/u.test(text);
}

/** More dictated words on the end of the box: a space between, none after a line break or a space. */
export function joining(existing, addition) {
  if (!existing) return addition;
  return /\s$/u.test(existing) ? existing + addition : `${existing} ${addition}`;
}

/** The text cut into what the box draws: plain runs and a marker in front of each line break (the break itself follows). */
export function segments(text) {
  const out = [];
  const lines = normalizeNewlines(text).split('\n');
  lines.forEach((line, i) => {
    if (line) out.push({ text: line });
    if (i < lines.length - 1) out.push({ marker: MARKER }, { text: '\n' });
  });
  return out;
}

/** For labels that show text that was already sent: the marker in front of each line break. The text itself is untouched. */
export function displayed(text) {
  return normalizeNewlines(text).replaceAll('\n', `${MARKER}\n`);
}

/** What a screen reader gets: each line break as "new line". */
export function spoken(text) {
  const parts = [];
  normalizeNewlines(text).split('\n').forEach((line, i) => {
    if (i > 0) parts.push('new line');
    if (line) parts.push(line);
  });
  return parts.join(', ');
}
