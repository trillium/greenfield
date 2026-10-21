// Speech to text with the browser's own recognizer: SpeechRecognition, or webkitSpeechRecognition on Safari (iOS and macOS). It
// needs a secure page (https, or localhost) and the microphone, and it only listens while this page is open and in front. Where a
// browser has no recognizer the Dictate screen says so and the text box still works with the keyboard.

import { joining } from './text.js';

/** Whether this browser can dictate, and if not, why in plain words. */
export function speechSupport(win = globalThis) {
  const Recognition = win.SpeechRecognition ?? win.webkitSpeechRecognition;
  if (!Recognition) {
    return { supported: false, reason: 'This browser cannot turn speech into text. Use Safari on an iPhone or iPad, or Chrome or Edge on a computer. You can still type into the box and send it.' };
  }
  if (win.isSecureContext === false) {
    return { supported: false, reason: 'The microphone needs a secure page (https). Open this app from its https address, then try again.' };
  }
  return { supported: true, Recognition };
}

/** The words of an error from the recognizer, with what to do. */
export function speechErrorMessage(code) {
  switch (code) {
    case 'not-allowed':
    case 'service-not-allowed': return 'Microphone or speech access is off for this page. Allow it in the browser (and in Settings, for Safari on iPhone), then try again.';
    case 'audio-capture': return 'No microphone was found.';
    case 'network': return 'The browser\'s speech service could not be reached. Dictation needs an internet connection.';
    case 'language-not-supported': return 'This browser cannot recognise that language.';
    case 'no-speech': return 'Nothing was heard.';
    default: return `Speech recognition stopped (${code}).`;
  }
}

/** The finished phrases and the one still being heard, from a recognizer's `results` list. */
export function readResults(results, fromIndex) {
  const finals = [];
  let interim = '';
  for (let i = fromIndex; i < results.length; i++) {
    const text = (results[i][0]?.transcript ?? '').trim();
    if (!text) continue;
    if (results[i].isFinal) finals.push(text);
    else interim += (interim ? ' ' : '') + text;
  }
  return { finals, interim };
}

/** Appends finished phrases to the box the way the phone does: a space between, none after a line break. */
export function addPhrases(box, finals) {
  return finals.reduce((text, phrase) => joining(text, phrase), box);
}

/**
 * Tap to start, tap to stop. `on` has: phrase(text), interim(text), state('listening'|'idle'), error(message).
 * A recognizer that ends by itself (Safari does after a pause) is started again while the person still wants to dictate, unless it
 * stopped at once, which would loop.
 */
export class Dictation {
  constructor(Recognition, on, { lang = 'en-US', now = () => Date.now() } = {}) {
    this.Recognition = Recognition;
    this.on = on;
    this.lang = lang;
    this.now = now;
    this.wanted = false;
    this.recognizer = null;
  }

  get listening() {
    return this.wanted;
  }

  start() {
    if (this.wanted) return;
    this.wanted = true;
    this.begin();
  }

  stop() {
    this.wanted = false;
    this.recognizer?.stop();
    this.on.interim('');
    this.on.state('idle');
  }

  begin() {
    const r = new this.Recognition();
    r.lang = this.lang;
    r.continuous = true;
    r.interimResults = true;
    this.startedAt = this.now();
    r.onstart = () => this.on.state('listening');
    r.onresult = (event) => {
      const { finals, interim } = readResults(event.results, event.resultIndex);
      finals.forEach((p) => this.on.phrase(p));
      this.on.interim(interim);
    };
    r.onerror = (event) => {
      if (event.error === 'no-speech' || event.error === 'aborted') return;
      this.wanted = false;
      this.on.error(speechErrorMessage(event.error));
    };
    r.onend = () => {
      this.on.interim('');
      if (this.wanted && this.now() - this.startedAt > 1000) return this.begin();
      this.wanted = false;
      this.on.state('idle');
    };
    this.recognizer = r;
    try {
      r.start();
    } catch (error) {
      this.wanted = false;
      this.on.error(speechErrorMessage(error?.name ?? 'start-failed'));
      this.on.state('idle');
    }
  }
}
