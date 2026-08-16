Type: prototype
Status: resolved

# Octet Tabber State Machine & E-Ink Selection Control

## Question

How should the Octet Tabber state machine model segment selection, numeric overwrite, arrow key deselection/navigation, and backspace substring clearing, and how does this state translate into high-contrast partial screen redraws on e-ink?

## Answer

Implemented and validated via [src/octet_tabber.lua](file:///home/mser/Documents/cla/exp/down2e/src/octet_tabber.lua) and [tests/test_octet_tabber.lua](file:///home/mser/Documents/cla/exp/down2e/tests/test_octet_tabber.lua).

Key validated mechanics:
1. **Segmented Data Model**: Segments are stored as discrete tokens (`o1`, `o2`, `o3`, `o4`, `port`, `path`) with an active segment index (1..6) and a boolean `is_selected` flag.
2. **Tab & Tap Selection**: `tab()` and direct touch taps focus the target segment with `is_selected = true`.
3. **Overwrite on Input**: Entering a digit when `is_selected == true` overwrites the segment, transitions `is_selected = false`, and subsequent digits append up to valid boundaries ($\le 255$ for octets, $\le 65535$ for port).
4. **Arrow Key Deselection**: $\leftarrow$ and $\rightarrow$ cancel selection without modifying text, placing the cursor at character position 1 or the end of the segment.
5. **Backspace Substring Clearing**: Pressing $\⌫$ when `is_selected == true` clears the entire active segment (`""`). When not selected, deletes character before cursor.
6. **E-Ink Partial Repaint**: Selected tokens are rendered with `Blitbuffer.COLOR_BLACK` background and `Blitbuffer.COLOR_WHITE` text; unselected tokens render normal text. Only the composer bounding box is dirtied on update.
