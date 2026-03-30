# ReaOrganize — User Manual
**Version 1.42** | by vazupReaperScripts

---

## 1. Introduction

ReaOrganize is a session organizer for REAPER. It gives you a persistent GUI to design your session's routing structure before committing it — defining groups of tracks, their send routing, FX chains, panning and colors — and then executes everything in one click via the **RUN** button. The core idea is that ReaOrganize works as a **blueprint layer** on top of your REAPER session. You define how your session should be structured in the script, and RUN builds it.

**Requires:** The ReaImGui extension (install via ReaPack: Extensions > ReaPack > Browse packages > search "ReaImGui").

### Basic workflow

1. Open ReaOrganize from the REAPER Scripts menu.
2. The **Track Panel** (right) lists all tracks in your session.
3. The **Group Panel** (left) lets you define groups — named, colored buckets with send routing, FX chains and send slots.
4. Assign tracks to groups using the Group dropdown in the Track Panel.
5. Configure your groups: set names, colors, routing, FX chains and sends.
6. Hit **RUN** — ReaOrganize creates folder tracks, colors child tracks, wires up sends and applies FX chains.

---

## 2. Group Panel

The Group Panel is the left side of the window. It is the heart of ReaOrganize.

### Groups Table

Each row represents one group. Groups are created with **Add Group** and removed with the **X** delete button on each row.

| Column | Description |
|---|---|
| **#** | Group number and selection checkbox. Click to select/deselect. |
| **Group Name** | Editable name field. This becomes the folder track name in REAPER. |
| **X** | Delete this group. CTRL+click deletes all selected groups. |
| **Color** | Set the groups track's color — opens REAPER's native color picker. |
| **R** | Randomize the color. |
| **A** | Cycle alternates through brightness steps for the color. |
| **Routing** | Dropdown: where this group routes to. "-> Master" or "-> [Group Name]" for nested groups. |

### Send Slots

Each group can have up to 8 send slots. These represent aux send tracks that will be created for the tracks assigend to that group.

Each send slot has:
- **Name** — the send track name
- **Color** — the send track color
- **FX** — an FX chain assigned to the send track
- **S / 0 / inf / clr** — set a custom dB value / set to 0dB / set to -inf / clear the send value for all tracks in this group
- **Pre** — checkbox for pre-fader mode

### Global Sends

Below the groups table is the **Global Sends** section. Global sends are shared send tracks that can receive from all tracks in the session. They are placed at the bottom of the session.

Each global send has the same controls as group sends (name, color, FX, S/0/inf/clr, Pre).

### Options Panel

Below Global Sends is the **Options** section:

| Option | Description |
|---|---|
| **FX Folder** | Custom folder path for `.RfxChain` files. Defaults to REAPER's FXChains folder. |
| **Global Filter** | Hides specific types of Plugins/chains. |
| **Sends Position** | Place send tracks at the top/bottom of the group, or at the bottom of the session. |
| **Parent Color** | Custom shared color for all group tracks. Option to use the individual group track colors, set in the group panel instead. |
| **Send Color** | Default color for newly created send tracks. |
| **FX Bypass** | Bypass created insert FX and/or FX chains on RUN. |

### Buttons: Add Group / Add Groups / Remove Last / Remove All

Located below the options panel. **Add Groups** prompts for a number to add multiple groups at once.

---

## 3. Track Panel

The Track Panel is the right side of the window. It lists every track in your REAPER session.

### Columns

| Column | Description |
|---|---|
| **#** | Track number, colored with the assigned group color. |
| ☑ | Selection checkbox. Header checkbox selects/deselects all. |
| **Track Name** | Editable inline — changes are applied immediately to REAPER. |
| **Group** | Dropdown to assign the track to a group. |
| **◎◎** | Stereo pair checkbox. Links this track with the one below and executes "Xenakios/SWS: Implode items to takes and pan symmetrically". |
| **Pan** | Pan value (e.g. `C`, `30L`, `45R`). CTRL+Enter applies to all selected tracks. |
| **S1–S8** | Send value fields per active send slot. CTRL+Enter applies to all selected tracks. |
| **GS1–GS8** | Global send value fields. CTRL+Enter applies to all selected tracks. |
| **FX** | Assigned FX chain for this track. Click to open the FX picker. CTRL+Select FX applies to all selected tracks. |

### Buttons below the Track Panel

| Button | Description |
|---|---|
| **Refresh** | Re-scans all REAPER tracks and updates the list. |
| **Clear Groups** | Removes all group assignments from all tracks. |
| **Set All** | Opens a scope modal with a value field — sets all send values in the track panel to the typed value. |
| **0 All** | Sets all send values to 0 dB (All or Selected tracks). |
| **inf All** | Sets all send values to -inf (All or Selected tracks). |
| **Clr All** | Clears all send values (All or Selected tracks). |
| **Ctr Pan** | Centers pan for all eligible tracks (All or Selected). |
| **Spr Pan** | Spreads pan across eligible tracks. Enter a spread value (0–100) in the field next to the button. |
| **Set Track FX** | Step-through modal to assign FX chains to tracks one by one. |
| **Guess Track FX** | Auto-applies the first matching FX chain (by track name) to All or Selected tracks. |
| **Save / Load** | Debug helpers: save/load the full track panel state to REAPER's ExtState. |
| **← / →** | Undo / Redo (20 steps). |
| **RUN** | Executes the full session build. |

Note: If there is no value in the tracks send tab, no send routing will be created. If there is "-inf" in the tracks send tab, a send routing will be created with a value of -inf. So with that you can decide which tracks of a group will be actually routed to that send.

### Scope Prompt

Many buttons open a scope prompt with three choices:
- **All** — apply to all tracks
- **Selected Only** — apply only to selected tracks
- **Cancel** — Cancels the prompt

Press **ESC** to close any modal.

---

## 4. Master Panel

The Master Panel is at the bottom of the Group Panel. It controls the REAPER Master Track's FX chain.

- Click the **FX** button to assign an FX chain to the Master Track.
- Click the **X** button to clear it.
- The Master FX chain is applied on every RUN.

---

## 5. Set FX / Guess FX

These two features help you quickly assign FX chains to groups, global sends and the master — based on name matching against your FX chain folder.

### Set FX (Group Panel)

Opens a step-through modal that walks through every group, every global send, and the master one by one.

For each item:
- The **name** is shown in large text.
- The **current FX chain** (if any) is shown in green, with an **X** to clear it.
- A list of **matching FX chains** from the FX folder is shown (matched by name containment, case-insensitive).
- Double-click a chain to apply it and advance automatically.

**Buttons / Keys:**
| Action | Description |
|---|---|
| **Apply** | Assign the selected chain and move to next |
| **Skip** / SPACE | Skip this item, move to next |
| **Cancel** / ESC | Stop the process |
| **← / →** | Navigate freely between items |
| **Double-click** | Apply and advance |

### Guess FX (Group Panel)

Opens the All / Selected / Cancel scope modal and auto-applies the **first matching FX chain** to all groups (and global sends + master when "All" is chosen). No manual selection needed.

### Set Track FX / Guess Track FX (Track Panel)

Same functionality, but for tracks. **Set Track FX** steps through all tracks one by one. **Guess Track FX** auto-applies first matches to All or Selected tracks.

---

## 6. Preset Slots, Export and Import

### Preset Slots

ReaOrganize has 8 preset slots displayed in the Group Panel. Each slot can store the complete state of the Group Panel (all groups, sends, global sends, options and master).

| Button | Description |
|---|---|
| **Store** (green) | Save current group panel state into this slot. |
| **Load** | Load this slot's state into the group panel. |
| **X** | Delete this preset slot. |

Presets are saved to REAPER's ExtState and persist between sessions and REAPER restarts.

### Export / Import / Capture buttons

Five buttons at the bottom of the Group Panel:

| Button | Description |
|---|---|
| **Export** | Export all preset slots to a `.roPre` file. |
| **Import** | Import preset slots from a `.roPre` file. |
| **Capture** | Capture the current REAPER session into the group panel (see Section 7). |
| **Set FX** | Step-through FX assignment modal for groups, sends and master (see Section 5). |
| **Guess FX** | Auto-apply FX chains by name matching (see Section 5). |

---

## 7. Capture Function

The **Capture** button scans your current REAPER session and automatically populates the Group Panel from what it finds.

### What gets captured

| Element | How it's captured |
|---|---|
| **Groups** | All folder tracks become groups — name, color, pan and routing (nested folders → parent group, top-level folders → Master). |
| **Group Sends** | Non-folder tracks inside a folder (with at least one incoming send) become send slots for that group. |
| **Global Sends** | Non-folder top-level tracks with at least one incoming send become global sends. |
| **FX chains** | The FX chain of each captured folder, send and global send track is extracted and saved as a `.RfxChain` file. |
| **Master FX** | The Master Track's FX chain is captured and saved as `Master.RfxChain`. |

### Capture workflow

1. Click **Capture**.
2. Confirm the overwrite prompt.
3. Enter an optional **Prefix** and **Suffix** for the generated `.RfxChain` filenames. The suffix defaults to today's date (ddmmyyyy). Leave either field empty to omit it.
4. If any `.RfxChain` files would be overwritten, a conflict dialog appears with three choices: **Overwrite**, **Unique Name** (appends `_01`, `_02` etc.) or **Cancel**.
5. Capture runs and the Group Panel is populated.

### Notes

- If your session has more folder tracks than the current number of groups, new group slots are added automatically (up to the maximum of 100).
- All captured FX chains are saved to the configured FX folder (or REAPER's default FXChains folder).
- A send track is recognized by having at least one incoming send from another track.

---

## 8. Key Commands / Shortcuts

### Group Panel

| Shortcut | Target | Action |
|---|---|---|
| CTRL + click | Group checkbox | Exclusive select — deselects all, selects only groups routing to same destination |
| SHIFT + click | Group checkbox | Range select from last clicked |
| ALT + click | Group checkbox | Exclusive single select (just this group) |
| CTRL + drag | Group drag handle | Move all selected groups together |
| CTRL + click | Delete (X) button | Delete all selected groups |
| CTRL + click | Folder FX X button | Clear folder FX on all selected groups |
| CTRL + click | Color swatch | Apply chosen color to all selected groups |
| SHIFT + click | Color swatch | Apply chosen color to entire subtree |
| CTRL + click | R button | Randomize color for all selected groups |
| SHIFT + click | R button | Randomize color for entire subtree |
| CTRL + click | A button | Cycle brightness for all selected groups |
| SHIFT + click | A button | Cycle brightness for entire subtree |
| CTRL + | Routing dropdown | Apply same routing to all selected groups |
| CTRL + click | Folder FX picker | Apply FX to all selected groups |
| SHIFT + click | Folder FX picker | Apply FX to entire subtree |

### Track Panel

| Shortcut | Target | Action |
|---|---|---|
| CTRL + click | Track checkbox | Exclusive select — deselects all, selects only tracks in same group |
| ALT + click | Track checkbox | Exclusive single select (just this track) |
| SHIFT + click | Track checkbox | Range select |
| CTRL + click | Track FX picker | Apply FX to all selected tracks |
| SHIFT + click | Track FX picker | Apply FX to all tracks in same group hierarchy |
| CTRL + click | Track FX X button | Clear FX on all selected tracks |
| CTRL + Enter | Send field | Apply send value to all selected tracks |
| CTRL + Enter | Pan field | Apply pan value to all selected tracks |

### Set FX / Set Track FX Modal

| Shortcut | Action |
|---|---|
| SPACE | Skip current item |
| ESC | Cancel and close |
| ← | Go to previous item |
| → | Go to next item |
| Double-click | Apply chain and advance |

### All Scope Modals (0 All, Clr All, Set All, Ctr Pan, etc.)

| Shortcut | Action |
|---|---|
| ESC | Cancel and close |

---

*ReaOrganize v1.42 — vazupReaperScripts — https://github.com/duplobaustein/vazupReaperScripts*
