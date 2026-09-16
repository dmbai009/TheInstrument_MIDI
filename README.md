# The Instrument — MIDI Chooser

A Garry's Mod addon that adds MIDI file playback to
[The Instrument](https://github.com/PinheadLarry1924/instrument). Instead of playing
notes by hand, you pick a `.mid` file and the addon performs it on the instrument —
solo, or with several players synchronised as a band.

This is a companion addon. The Instrument itself must be installed for it to do anything.

## Install

Drop the folder into your addons directory so the paths end up as:

```
garrysmod/addons/TheInstrument_MIDI/lua/autorun/client/cl_instrument_midi.lua
garrysmod/addons/TheInstrument_MIDI/lua/autorun/server/sv_instrument_midi.lua
```

Both files are `autorun`, so there is nothing to require or configure to get started.

## Use

Put `.mid` files into `garrysmod/data/the_instrument_midi/` — the addon creates that
folder on first run and lists everything in it.

Open the menu with an in-game button, or from console:

```
the_instrument_midi
```

Playback offers speed control, a seek bar, pause and looping.

### Band mode

Several players can play the same file together. One player hosts; the others join,
and the host's MIDI file is streamed to them over the network in chunks, so joiners do
not need the file on disk. Playback is phase-locked to the host, so everyone stays on
the same beat rather than drifting apart.

Transfer limits: 24 KB per chunk, 24 chunks maximum (roughly 576 KB per file) and a
20 second join timeout.

## ConVars

Client:

| ConVar | Default | Meaning |
|---|---|---|
| `theinstrument_midi_note_rate` | `80` | Maximum MIDI notes per second this client emits |

Server:

| ConVar | Default | Meaning |
|---|---|---|
| `theinstrument_midi_note_radius` | `2500` | How far notes are heard |
| `theinstrument_midi_action_cooldown` | `0.2` | Cooldown for play/stop actions |
| `theinstrument_midi_slider_cooldown` | `0.03` | Cooldown for seek/speed actions |
| `theinstrument_midi_join_cooldown` | `1` | Cooldown for band join requests |
| `theinstrument_midi_patch_relay` | `1` | `1` = unreliable patched relay |

## Limits

Dense MIDI files can flood a server with note events, so the addon caps things on both
sides: files above 4 MB or 200,000 notes are rejected, the client throttles its own note
rate, and the server applies per-action cooldowns and a session cap per host.

## Credits

Addon by dmbai. Built for [The Instrument](https://github.com/PinheadLarry1924/instrument)
by PinheadLarry1924.
