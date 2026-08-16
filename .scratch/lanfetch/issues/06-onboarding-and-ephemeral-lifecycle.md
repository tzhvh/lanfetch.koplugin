Type: grilling
Status: resolved

# Onboarding Flow & Ephemeral State Lifecycle

## Question

What exact first-run onboarding steps, visual shortcut hints, and default setting initialization should be presented, and how is the clean destruction of ephemeral in-memory state guaranteed on exit?

## Answer

Resolved and locked:
1. **First-Run Onboarding Wizard**:
   - Gated by `G_reader_settings:isTrue("lanfetch_onboarded")`.
   - Step 1: Base Download Folder Confirmation (defaults to `/mnt/onboard/documents/Downloads` with an option to browse).
   - Step 2: Visual Cheat-Sheet modal explaining `Tab` cycling, single-keystroke numeric overwrites, `Detect` subnet auto-fill, and `ABC` for full QWERTY keyboard.
   - `[ Got it, Start Fetching ]` button sets `lanfetch_onboarded = true`. An `[ ℹ Help ]` button on the main top bar allows revisiting this cheat-sheet anytime.
2. **Persistence vs Ephemerality Matrix**:
   - *Persisted via `G_reader_settings`*: `lanfetch_onboarded`, `lanfetch_base_dir`, `lanfetch_presets` list, `lanfetch_last_subfolder`, `lanfetch_default_port` ("9999"), `lanfetch_auto_open` (true).
   - *Strictly Ephemeral (RAM only)*: Active URL buffer, octet states, cursor position, download chunk buffers, and cancellation flags are instantiated per-session in `InputContainer` and wiped from memory upon `UIManager:close()`.
3. **Post-Download Action**:
   - Displays a success prompt: *"Downloaded: <filename.pdf>"* with `[ 📖 Open Book ]` and `[ Download Another ]`. If auto-open is enabled, loads directly into KOReader ReaderUI via `ReaderUI:showReader(target_path)`.
