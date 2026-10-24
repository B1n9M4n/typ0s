# typ0s

**Type fast. Fix later.** typ0s is a tiny macOS menu bar app that cleans up a messy paragraph in place, with one hotkey.

## Why I made this

I freewrite almost every day. Freewriting means you just keep typing: no fixing grammar, no going back, nothing except getting the idea out. I do it in Farza's [Freewrite](https://freewrite.io) app with **backspace turned off**, so there's no way to correct anything while I write.

The problem is that I'm not an accurate typer, especially on my new mechanical keyboard (a NuPhy Air75). I like typing fast because it's fun and the ideas in my head move fast, but every paragraph ends up full of typos: letters swapped, neighbouring keys hit by accident, the space bar landing one letter too early. Sometimes I even hit the language switch by accident and a whole phrase comes out in Thai letters. Since I can't backspace, the result is hard to read afterwards.

I didn't want an AI rewriting my words, and I didn't want to recheck every line by hand. I wanted something that:

- fixes the mechanical slips **after** I finish a paragraph, so I never break the flow while writing
- guesses from how keyboards actually work, but **doesn't guess** when it isn't sure the word is a real typo
- learns the typos I keep repeating, instead of me typing them into a dictionary
- runs entirely on my own Mac

That's typ0s.

Honestly, when I first wrote the idea down, my last line was "I think this is a dumb idea." I built it anyway, on purpose. I think making a small, easy app with a slightly dumb concept is important: it gives you the feeling of actually getting started and shipping something real, instead of waiting for the perfect big idea. This is that first thing for me.

### How I use it

1. Open Freewrite (or any editor), turn off backspace, and write as fast as you want.
2. At the end of a paragraph, press the hotkey (or double-tap Right Shift).
3. The paragraph is cleaned up in place, and I keep writing.

It works in any app where you type, not just Freewrite.

## What it does

- **Keyboard-aware**: knows which keys sit next to each other, so `teh`, `mornign`, `keybaord`, doubled keys and swapped letters get fixed.
- **Space slips**: `righ tnow` → `right now`, `th e` → `the`.
- **Wrong keyboard layout**: typed English while Thai (or another layout) was switched on by accident? `ะ้ำ ทนพืรเื` → `the morning`. Real writing in that language is left alone.
- **Learns your habits**: a typo you make twice is memorised. Names it doesn't know are protected after 3 uses. Press ⌘Z right after a fix and nothing from it is learned.
- **Careful**: if it isn't confident, it leaves the word alone.
- **Private**: no internet, no AI service, no account. Everything runs on your Mac.

## Install

1. Download `typ0s-x.y.z.zip` from the [Releases](../../releases) page and unzip it.
2. Drag **typ0s.app** into your **Applications** folder.
3. Open it. macOS will say it can't check the app (it isn't from the App Store or a paid Apple developer account):
   - Open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to typ0s.
   - Or, in Terminal: `xattr -dr com.apple.quarantine /Applications/typ0s.app`
4. When asked, allow **Accessibility** access (System Settings → Privacy & Security → Accessibility → turn on typ0s). typ0s needs it to see your hotkey and to replace text in other apps.

Requires macOS 14 (Sonoma) or newer. Works on Apple Silicon and Intel Macs.

## Use

1. Write your paragraph anywhere.
2. Select it, or just leave the cursor in the text box.
3. Press the hotkey: **⌥ Space** (Option + Space). On an external keyboard with an F14 key, **F14** works too.
   Double-tapping **Right Shift** also works. You can change the hotkeys in settings.

The keyboard icon in the menu bar flashes with the time it took. Click it to open settings: hotkeys, your learned dictionary, and a Test tab to try it out (Short, Long, and Classic texts with random slips and a score).

**Opening settings:** click the menu bar icon, or, if it's hidden behind the notch, search **typ0s** in Spotlight (⌘ Space) or press **⌥ ⌘ ,** from any app. In the settings window, **⌘ ,** reopens it, **⌘ W** closes it and **⌘ Q** quits typ0s.

## Build from source

You need Xcode or the Command Line Tools (`xcode-select --install`).

```bash
git clone <this repo>
cd typ0s
./build.sh
open build/typ0s.app
```

`build.sh` makes `build/typ0s.app` (Apple Silicon + Intel) and a zip for sharing. An app you build yourself doesn't get the "can't check this app" warning.

## Privacy

typ0s watches the keyboard only to notice its hotkeys and ⌘Z. It reads text only when you press the hotkey, and only from the text box you're in. Nothing is sent anywhere. Your learned words are saved locally on your Mac (in the app's preferences) and you can delete any of them from the Dictionary tab.

## Known limits

- Fixing with nothing selected rewrites the whole text box. In rich-text apps (Notes, Mail) that can drop formatting, so select the paragraph first there.
- Some web and Electron apps don't allow direct editing, so typ0s falls back to copy and paste and puts your clipboard back afterwards.
- It fixes slips, not grammar. A slip that makes another real word (`live` → `life`) usually can't be caught.
- Chinese Pinyin and other input methods can't be reversed when switched on by accident.

## How it decides

typ0s ships with an English word list (82,765 words) and a word-pair list (243k pairs), each with how often it's used. For an unknown word it looks at every real word within two keystroke slips, then picks the one that's the cheapest slip on a keyboard (neighbouring keys, swapped keys, a key that didn't register), the most common, and the best fit with the words around it. If it can't tell, it leaves the word alone.

The `tests/` folder has real typos from freewriting sessions (`real_typos.tsv`), older bugs (`regression.tsv`) and clean text that must never change (`clean_text.txt`).

## Credits

Word lists: [SymSpell](https://github.com/wolfgarbe/SymSpell) frequency dictionaries (MIT, Wolf Garbe), with counts from the Google Books Ngram data (CC BY 3.0). See `Dictionary/LICENSE.md`.

## License

MIT. See [LICENSE](LICENSE).
