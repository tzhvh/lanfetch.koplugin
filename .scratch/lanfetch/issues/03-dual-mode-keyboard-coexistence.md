Type: prototype
Status: resolved
Blocked by: 02

# Dual-Mode Keyboard Coexistence & Alphanumeric Handoff

## Question

How should the plugin interface manage the transition and layout handoff between the custom full-screen LAN Mode keypad and KOReader's native Alphanumeric Mode virtual keyboard / `InputDialog`?

## Answer

Implemented and validated via [src/url_handoff.lua](../../src/url_handoff.lua) and [tests/test_url_handoff.lua](../../tests/test_url_handoff.lua).

Key architectural mechanics:
1. **LAN Mode Default**: A full-screen `InputContainer` hosting discrete octet widgets and a high-contrast `ButtonTable` numeric/control keypad (`0-9`, `:`, `.`, `/`, `Tab`, `⌫`, `ABC`).
2. **Switching to Alphanumeric Mode**: Tapping `[ ABC / Full URL ]` exports the current `OctetTabber:getURL()` string and opens KOReader's native `InputDialog`. The user can type arbitrary domain names, complex URL paths, IPv6 addresses, or paste from clipboard using KOReader's full QWERTY virtual keyboard.
3. **Switching Back to LAN Mode**: If the user edits the URL in `InputDialog` and taps `[ ⇄ LAN Mode ]`, `URLHandoff.parseURL(url)` evaluates whether the host is a valid IPv4 address. If valid, it populates `OctetTabber` with the extracted octets, port, and path, returning smoothly to LAN Mode. If not (e.g. domain name or IPv6), it remains in Alphanumeric Mode with a brief notification.
4. **Direct Download from Either Mode**: Both modes feature a direct `[ ⬇ Download ]` button, ensuring zero mandatory round-trips if the user chooses to stay in Alphanumeric Mode.
