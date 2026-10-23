# typ0s

**Type fast. Fix later.** typ0s is a tiny macOS menu bar app that cleans up a messy paragraph in place, with one hotkey.

It was made for freewriting: writing with backspace turned off (for example in [Freewrite](https://freewrite.io)), typing as fast as the ideas come, and fixing the mess afterwards instead of rechecking every word.

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
3. Press the hotkey: **⌥ Space** on the built-in keyboard, **F14 / F5** on an external one. You can change these in settings.
   Double-tapping **Right Shift** also works.

The keyboard icon in the menu bar flashes with the time it took. Click it to open settings: hotkeys, your learned dictionary, and a Test tab to try it out (Short, Long, and Classic texts with random slips and a score).

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

## License

MIT. See [LICENSE](LICENSE).
