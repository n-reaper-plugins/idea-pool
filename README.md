# IdeaPool v0.2.1 – an ideas pool for REAPER

![image](screenshot.png)

One action (`IdeaPool.lua`) opens a ReaImGui window. **Stash** selected items (any tracks) as an *idea*, keep
**variants** of it, **place** it back as linked copies, **play** it on its own, and let a **marker** place it in the song.
Everything lives in the project.

## The window: three panes (drag the borders)
| Left, 50% – *see and edit* | Middle, 22% – *choose* | Right, 28% – *act* |
|---|---|---|
| waveform / notes of the active variant, piano roll, the numbers | **Stash** (name, button, what happens to the items), the **ideas list**: click a name to open it, **Play**, **Rename** in place | Play on its own, Place (3 ways), variants + loudness match, placements, delete, **Settings** (collapsible) |

## Install
**macOS (or `--portable` anywhere):** close REAPER, then `./install_mac.sh` (also finds `dist/IdeaPool.lua`); `--uninstall` removes it.
**Manual:** load `dist/IdeaPool.lua` via *Actions → New action → Load ReaScript…*. Needs **ReaImGui**; optional **js_ReaScriptAPI**
(syncing waits until you release the mouse). Running the action again closes the window.

## Stash and place
Select items and press **Stash selected items**; afterwards the items **stay** (copy, default), **become a placement**, or **are removed**.
The idea remembers the items with everything REAPER stores about them (take FX, envelopes …), their tracks, their colour, and the level of their audio.
**Place at cursor** (on the tracks it came from) · **Place on selected track** (first track there, the others keep their distance) ·
**Where it came from**. A placement is an empty MIDI item on the **IDEAS** track plus the real items:
* move / trim / split / copy the placement item – its items follow; cutting one of its items cuts the placement (the AliasTrack engine);
* **linked**: edit an item in any placement and every linked placement follows;
* **Freeze** – this placement stops following; its items and its placement item turn **grey**. **Unfreeze** shows the idea again;
* **Detach** – plain items; **MIXED** + **Apply / Revert** for what cannot follow automatically.
* Items of placements are coloured like their idea (setting); frozen ones are always grey.

## Play on its own
**Play** (list or right pane): temporary tracks appear at the end of the project, one per original track **with a copy of its FX chain**
(so instruments and effects sound as on the original), the idea is placed on them at the edit cursor, everything else is un-soloed,
playback loops over the idea. **A/B while it plays**: click a variant button and the audition switches at once; edit in the view and you hear it.
When playback stops – or you press **Stop**, or close the window – the temporary tracks go, your solo and loop settings come back.
No undo points are made. (Settings: copy FX chains, loop.)

## Variants and loudness-matched A/B
**Duplicate** makes variant B from the active one; **A / B** switch every linked placement (items updated in place);
**Save as variant** turns what a placement looks like now into a new variant. **Match loudness between variants** plays every variant at the level
of the *reference* variant (gated average, as in GainStageEQ); MIDI items are not affected.

## The idea view
One row per track, each item with its **waveform** (REAPER's peaks, prepared in the background) or, for MIDI, its **notes**
(click a MIDI item for a larger read-only **piano roll**).

| Drag | Does |
|---|---|
| the body | move the item inside the idea |
| the left / right edge | trim (the left edge also moves the file offset; stops at the file's start and end) |
| the small handles in the top corners | fade in / fade out – **audio only** |
| the top edge | gain – **audio only** |

Fades and gain do not act on MIDI items, so MIDI boxes have no such handles. One undo step per drag; **Snap to 1/16**; zoom; playhead.

## Markers
A marker named like an idea (case and spaces ignored) puts the idea there; a **region** trims it. The placement goes with the marker:
move it and the idea moves, rename or delete it and the idea is gone. **Rename an idea** and its markers are renamed too.
**Keep** (placement row) makes it an ordinary placement and removes the marker.

## Sub-lanes (setting, off by default)
New placements put their items on a **child track under each original track**, so they pass through that track's FX chain and volume.
Lanes appear when needed, disappear when empty, and folder depths are put back. **MIDI items stay on the original track** (a child track
cannot reach the parent's instrument). "Place on selected track" counts only real tracks.

## Undo, storage, settings
One undo step per command; syncs add none by default (*One step per edit*) – or one each (*Separate sync steps*).
The pool is JSON in the IDEAS track's `P_EXT` (saved with the project, part of undo); placements and items are tagged, never recognised by names.
**Detach all** forgets the pool, items stay.

## Development
`./tools/run_tests.sh` builds `dist/IdeaPool.lua` and runs the offline tests (Lua 5.3+) against a mock REAPER. `DESIGN.md`: model and decisions.
`spikes/`: what to confirm in real REAPER. MIT licence.
