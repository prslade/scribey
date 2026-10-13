# Scribey

Hold-to-dictate for macOS, fully offline. Hold right-⌥, talk, let go, and the text is pasted at your cursor. Transcription runs on your Mac with NVIDIA's Parakeet TDT v2 model via [parakeet-mlx](https://github.com/senstella/parakeet-mlx); audio never leaves the machine.

```
git clone https://github.com/mickrudolph/scribey && cd scribey && ./install.sh
```

Or paste this to your agent:

```
Clone https://github.com/mickrudolph/scribey and run ./install.sh. If it stops on a missing prerequisite, install it and run ./install.sh again.
```

Then grant **Accessibility** (for the hotkey and paste) and **Microphone** when macOS asks, or in System Settings → Privacy & Security. The hotkey starts working within a second of granting Accessibility.

## Needs

- An Apple Silicon Mac
- Xcode Command Line Tools (`xcode-select --install`)
- Python 3.12 and ffmpeg (`brew install python@3.12 ffmpeg`)
- ~2.5GB of disk for the model, downloaded once on first install

## Using it

- **Hold right-⌥** to record, release to transcribe and paste.
- **Double-tap right-⌥** to lock into continuous recording; tap again to stop.
- **Esc** cancels a recording without transcribing.
- The menu-bar mic icon has **Stop Recording** (if the overlay ever gets stuck), **Mute Sound Effects**, **Lower Music While Dictating**, **Custom Words**, and **Quit**.
- While recording, the system output volume drops to ~12% and eases back up over ~2s afterward (on by default; toggle in the menu). Touching the volume keys mid-fade wins.
- A floating pill shows recording/transcribing state with a live level meter.
- Pasting goes through the clipboard and restores whatever you had copied afterward.

## Custom words

If it keeps misspelling a name or term, add it from the menu bar: **Custom Words → Add Word…**. Click a word in that menu to remove it. The words live in `daemon/custom_words.txt` (**Open Word List…**), which explains the three formats (fuzzy match, exact aliases, context rules). Changes apply on the next dictation.

You start with a few defaults from `daemon/custom_words.default.txt`. Your list is yours: it isn't tracked by git, so your changes never conflict with a `git pull` and never end up in the repo. Delete `custom_words.txt` to start over from the defaults.

## Install details

`./install.sh` builds the Python environment and downloads the model, builds and signs `Scribey.app` into /Applications, and installs a LaunchAgent so Scribey starts at login and restarts if it crashes. Re-run it after pulling changes.

Keep this folder: the transcription daemon and your custom words live here, and the app runs them from here.

The app is signed ad-hoc, so macOS forgets its Accessibility permission after every rebuild (including re-running `./install.sh`). Remove Scribey from Privacy & Security → Accessibility with **–**, then add `/Applications/Scribey.app` again with **+**. If you have a signing certificate, `SCRIBEY_SIGNING_IDENTITY="<identity>" ./install.sh` avoids that.

Logs: `/tmp/scribey.log` (app) and `~/Library/Application Support/Scribey/daemon.log` (transcription, with per-clip timing).

To remove everything: `./uninstall.sh`, then delete this folder.
