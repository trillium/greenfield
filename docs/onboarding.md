# Greenfield from nothing to inserted text

You speak on your iPhone. The words appear, typed, into a document on your Mac.

This page is the whole setup, in order, for a Mac and an iPhone that have never seen Greenfield before. It
assumes no account, no reading of anything else, and **nothing you have to type**: no key, no address, no
computer name. Every step below is found by the app itself, explained in one line, and fixed with one tap or
one command.

Do the Mac first (Part 1), then the phone (Part 2). Part 3 is only for when something is red.

**You are done when:** you have said a sentence on the phone and seen it appear, as text, in a document on the
Mac.

---

## Part 1 - The Mac

Time: about two minutes, of which you spend about thirty seconds on one switch.

### 1. Run one command

Open Terminal on the Mac. Go into the Greenfield checkout (the folder you cloned it into) and run:

```
mac/install.sh
```

That one command builds the small Mac program that inserts text, installs it so it starts at every login, and
then shows a live checklist that turns green as each step lands. It never asks you a question and never waits
for you to type anything. When it finishes it prints a link and a square code that adds this Mac to your phone.

To see what it will do before you run it: `mac/install.sh --help`.

### 2. The one thing only you can click: Accessibility

macOS asks (or has already asked) for permission to let Greenfield press keys and read the text in the focused
field. Until that is granted, no computer on this Mac can type anything for anyone.

Approve it: **System Settings > Privacy & Security > Accessibility**, and switch on the row named
`greenfield-inserter`. It appears in that list once macOS has seen the request.

If you dismissed the prompt and the row is not there, run this on the Mac and macOS will ask again:

```
make -C mac permissions
```

This is the only step in Part 1 that a script cannot do for you, and it is a switch, not a document.

### 3. Ask "am I ready?"

```
greenfield-inserter ready
```

It prints either `Ready.` or `Not ready yet. Next step: ...` naming exactly one thing left to do, in plain
words. Do that one thing and run it again. The phone asks the same question about its own half, in Part 2.

### 4. Keep the link and the square code

At the end of step 1, and any time later, this prints a `greenfield://add` link and a square code (a QR code)
for this Mac:

```
greenfield-inserter link
```

You never type it. In Part 2 you either open that link on the phone, or point the phone's camera at the square
code through the app.

---

## Part 2 - The phone

Time: about five minutes, most of it a one-time download.

### The checklist

The first time you open Greenfield it fills the screen with **Get ready**: everything that has to be true,
top to bottom, each line with one button that fixes it. Work down the list, one tap per line.

1. **Microphone** - tap *Allow the microphone*. Greenfield listens on this phone only; no audio leaves it.
2. **Local network** - tap *Allow the local network*. Without this the phone cannot see computers on the same
   Wi-Fi, even when they are right there.
3. **Tailscale** - turn Tailscale on for this phone. Greenfield reaches your Mac over Tailscale. The phone and
   the Mac must be on the same tailnet (the same Tailscale account, as the same user): the Mac accepts text
   from devices of its own tailnet user and from nowhere else.
4. **Speech model** - tap *Download the speech model*. About 0.5 GB, once, and the line shows the percentage as
   it goes. Leave the app open. This is the longest step by far.
5. **Sound detector** - tap *Start the sound detector*. It listens for kitty-cmere and tongue clicks.
6. **Your computer** - tap *Look for computers*. See below; this one is found, not typed.

When a Mac is found and answers, the computer line turns green by itself. **If exactly one computer answers,
the app chooses it for you** - there is nothing to tap.

Under the list there is *Scan the computer's code* (for the square code from Part 1, step 4) and, at the
bottom, *Guided first dictation: say hello, then send it* (Part 2, step 5).

Under the main screen there is one line that answers "am I ready?" and names your single next step. Tap it to
reopen the checklist whenever you like. It is also under **Help > Get ready**.

### How the phone finds your Mac

Three ways, all of them automatic, all of them needing nothing from you:

- **Over the tailnet.** The Mac is on the same tailnet as this phone and is awake with the daemon running. The
  phone finds it on its own.
- **Over the local network.** A Mac on the same Wi-Fi shows up under *Found on your network* on the
  **Computers** tab; tap it once to add it.
- **By the code.** Open the `greenfield://add` link on the phone, or scan the square code with the app's
  scanner.

### Computers

The **Computers** tab lists the Macs this phone can send to, with a dot for whether each one answers. Tap a
computer to make it the one your text goes to; text always goes to exactly one computer. *Check* at the top
asks again now instead of in a few seconds.

Nothing on this tab asks you to type. There is an **Advanced** row at the very bottom, which is a last resort:
it is the only screen in the app with a field you can type into, and none of the steps in this page need it.

### Assist

The **Assist** tab is the phone as a trackpad and a window switcher for the Mac you chose (the same Mac as
the *Computers* tab: change it from the *Computer* menu at the top of the tab). It is **off on every Mac until
that Mac's owner turns it on**, so a new Mac shows *Assist is off on* its name, with one step under it. The
step is a command on the Mac, in Terminal:

```
greenfield-inserter assist on
```

Then tap *Check again* on the phone. The trackpad has its own switch, `greenfield-inserter assist pointer on`;
until it is on, only *Windows* is offered. `greenfield-inserter assist off` turns everything off at once, and
the phone says so the next time it asks. Nothing on the phone can turn assist on, and nothing here needs a
key or an address: the Mac lets in the devices of its own tailnet user, as for text.

*Assist is off* is not a fault. **Help > Health** says it in one informational line ("Assist on ..."), not as a
warning, and the summary stays green. A Mac too old to have assist shows *has no assist tools* instead, with the
update step.

Every control on these screens has a button and a spoken name, so Voice Control can reach all of it: the
trackpad has a button for every gesture, and *Stop* is always at the top.

### Health

**Help > Health** checks everything at once and says, in plain words, what is wrong and what to do about it. It
is the answer to almost any "why is this not working". Its last row, **Can actually insert text**, is the one
that counts: it is green only when text has really arrived in a real field on the Mac. If that row is red, run
the selftest from Part 3, step 8.

### Say something

Go to the **Dictate** tab, in the Mac app you want to write into, with your cursor where you want the text.

1. Say **kitty-cmere** twice. The app starts listening. (Or tap the microphone button once; it is the same
   thing.)
2. Say your sentence.
3. Say one **tongue click** to stop. The words land in the text box, where you can read them, change them, or
   try again.
4. Say **send it** (or tap **Submit to ...**). The text goes to the computer you chose, and the Mac types it
   into whatever was focused there.

That is the whole setup.

### If you would rather not learn the sounds yet

At the bottom of the checklist, *Guided first dictation: say hello, then send it*. Tap *Start*, say **hello**,
then say **send it**. It sends the word hello through the whole real path - microphone, speech model, delivery,
the Mac typing it - and then tells you Pass or Fail in words.

---

## Part 3 - When something is red

Every message the app or the Mac gives you names one problem and one fix. This page lists the ones you can meet
on the first day.

### 1. "Next step: Switch on Accessibility" (on the Mac)

This is the live checklist from `mac/install.sh` or `greenfield-inserter ready`, and the one step that is
waiting for you.

**Fix:** System Settings > Privacy & Security > Accessibility, switch on `greenfield-inserter` (Part 1, step 2).
Nothing else on the Mac can be wrong before this is done; when it lands, the Mac restarts itself and the
checklist continues by itself.

### 2. "Update the Mac daemon" or "Update the app" (on the phone)

The app and the Mac program speak a versioned protocol, and one side has to be updated.

**The rule.** While the MAJOR version is 0, the **MINOR** of the app and the **MINOR** of the Mac's daemon must
be the same; the patch number may be anything. From 1.0.0 on, the MAJOR must be the same and the minor may be
anything. So an app 0.2.3 works with a daemon 0.2.9 and refuses 0.1.x and 0.3.x.

**"Update the Mac daemon"** - the Mac is too old for this app. On the Mac:

```
make -C mac install
```

That builds, signs, installs, restarts and checks that the running program is the one just installed (if the
new one does not come up, it puts the old one back and tells you). Already have a signed build you want to
use? `greenfield-inserter update --from FILE`. Then tap *Check* again on the phone.

**Several Macs, one certificate.** The signing certificate's private key may live on only one Mac, and
`codesign` cannot use it over ssh (the keychain is locked there). Build once, sign on the Mac that has the
certificate from a program running in its desktop session, check the result, and install that same file on
every Mac:

```
codesign --force --sign "Apple Development: Name (ID)" --identifier greenfield-inserter FILE   # desktop session
codesign -dvv FILE 2>&1 | grep TeamIdentifier                                               # your team id
greenfield-inserter update --from FILE      # on each Mac, from its desktop session; keeps config and keys
greenfield-inserter macs health             # Accessibility granted, Version matches, App compatible
```

The same certificate means macOS keeps the Accessibility approval, so no Mac needs a click. Run the update
one Mac at a time, and never delete `~/.config/greenfield-inserter` (it holds the settings and the key).

**After an update, run `greenfield-inserter selftest` once on each Mac.** A restarted daemon has seen no
delivery yet, so *Can actually insert text* is a FAIL line in `health` until the selftest (or a real text)
has arrived. The selftest needs the screen unlocked: on a locked screen it stops at *Screen not locked* and
says to unlock the Mac. Unlock, run it, and the Health line turns green.

**"Update the app"** - this app is too old for the daemon. Install the newest Greenfield on the phone (or build
it from the checkout), then tap *Check* again. To update the copy already on the phone without losing its
data, build it signed for the phone and install over it, never uninstall first:

```
make core && scripts/version.sh --write && make generate        # once per checkout; Config/Local.xcconfig sets DEVELOPMENT_TEAM
xcodebuild -project DictationApp.xcodeproj -scheme DictationApp -destination 'id=<phone udid>' \
  -derivedDataPath build/DerivedData -allowProvisioningUpdates build                            # desktop session (signing)
xcrun devicectl device install app --device <phone> build/DerivedData/Build/Products/Debug-iphoneos/DictationApp.app
```

Installing does not launch the app, so the phone can stay locked. Opening it (to see Health, or
`make logs TARGET=phone`) needs the phone unlocked once. `make logs` writes under `~/Library/Logs`; it refuses
a folder inside a git repository.

### 3. The phone cannot find the Mac

The Mac is not in the phone's list, or the computer line never turns green. In the order worth checking:

1. **Tailscale off somewhere.** Tailscale must be on for both the phone and the Mac. This is the usual cause.
2. **Different tailnets.** The phone and the Mac must be on the same tailnet, as the same user. The Mac only
   accepts text from devices of its own tailnet user, so a phone signed into a different account will never be
   accepted, and the phone says so rather than hanging.
3. **The Mac is asleep, or shut down.** Wake it.
4. **The daemon is not running.** On the Mac, `greenfield-inserter ready` answers in one line. If it says the
   next step is not Accessibility, `make -C mac install` puts it back.
5. **Local network is off on the phone.** A Mac on the same Wi-Fi is invisible without it; give the **Local
   network** line on the checklist a tap.
6. **It was never added.** Scan the square code again (Part 2), or open the link from `greenfield-inserter link`
   on the phone.

Then tap *Check* on the **Computers** tab, or *Look for computers* on the checklist.

### 4. "its screen is locked"

The Mac's screen is locked, so text cannot be typed yet. Nothing is lost: the phone keeps the text in the
**Waiting to send** list (in the *Computers* tab) and the message says its screen is locked.

**Fix:** unlock the Mac, then tap *Retry all* under *Computers > Waiting to send* (or *Retry* on the waiting item). The phone retries
by itself as well.

### 5. "a password field is focused"

macOS does not let any program type into a password field, so Greenfield refuses rather than typing your
password into the wrong place.

**Fix:** click into an ordinary text field on the Mac, then retry.

### 6. Nothing arrives

Open **Computers > Waiting to send** (the *Computers* tab also shows how many are waiting). Every text that has not been delivered is there, with the plain reason it is
waiting: its screen is locked, a password field is focused, the phone is not the same tailnet user as that
Mac, the daemon is not answering, the app and the daemon are on different lines of the compatibility rule.

Fix the reason it names, then **Retry all**. The same text is never typed twice by two Macs: each submission
carries an id, and a Mac that already took it answers that it did.

### 7. `greenfield-inserter doctor` (on the Mac)

The Mac's own version of **Health**, and the deeper one: it checks the daemon, what it is listening on, who it
accepts, Accessibility, the lock, password fields, the version line, the peer Macs, and whether text really
arrives. For every failed check it prints what is wrong, why it matters, and the exact fix.

```
greenfield-inserter doctor
```

A fast yes/no instead of the full explanation is `greenfield-inserter health` (it exits 0 only when everything
is good). From the checkout the same commands are `make -C mac doctor` and `make -C mac health`.

### 8. `selftest` (on the Mac) - does it really type?

This proves the Mac can insert text with no phone involved. It opens a small window with a text field, sends a
unique harmless test string and a Return through the real daemon, reads the field back to prove they arrived,
closes the window, and prints `PASS` or `FAIL` with the fix.

```
make -C mac selftest
```

The window takes the keyboard focus for a few seconds, so do not type while it runs. This is what the
**Can actually insert text** row on the phone's Health tab is based on; run it once and that row turns green
for a week. `greenfield-inserter doctor` runs it for you when everything else is already fine.

---

## Where things are

| Thing | Where |
|---|---|
| The Mac program (installed) | `~/.local/share/greenfield-inserter/greenfield-inserter` |
| The Mac program (this checkout) | `mac/`, built with `make -C mac build` |
| The Mac's settings and log | `~/.config/greenfield-inserter/inserter.log` |
| This page's steps, automated | `scripts/onboarding-check.sh` (and `--fast` while you work) |
| How the phone and the Mac talk | `docs/mac-contract.md` |
| Versions and the MINOR rule | `docs/versioning.md`, `docs/mac-contract.md` |