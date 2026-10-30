# History

What changed in each version of Pickup, in plain words. `CHANGELOG.md` is the technical list generated from the
commits at release time; this file is written by hand and can be used for release notes, the website or posts.

## 0.3.0 (upcoming)

**Recent calls in the menu bar.** With an empty search field, the popover shows your phone's recent calls in three
tabs: Outgoing, Incoming and Missed. Every row has its own call button; unknown numbers can be added to the
contacts app you use on your Mac (Contacts, Cardhop, …), and ⌘C copies a number. The list comes straight from the
phone's call log over Bluetooth and is never stored on the Mac. While it loads for the first time, placeholder rows
show where it will appear.

**Call waiting, hold and swap.** When a second call comes in, the call window offers *Hold & Accept*, *End & Accept*
and *Decline*. A call can be put on hold and resumed, and with two calls you can swap between them or end the one on
hold. Works with phones that support three-way calling (the Pixel does).

**Never miss a call.** A missed call puts a small red dot on the menu bar icon, and the notification now has a
*Call Back* button.

**Your phone's battery.** Shown next to "Connected to …" in the popover, as a percentage in the menu bar, or not at
all (Settings).

**More comfortable.**
- The popover can be made wider by dragging its edge (up to twice its width); search and lists grow with it.
- Full keyboard control of the recent calls: Tab, the arrow keys, Return, Esc, ⌘1–3.
- Round keypad keys with more room below the search field.
- A welcome window explains the permissions Pickup needs, on first launch and, while Pickup is not yet signed by
  Apple, after updates.
- The German version now says "du".
- The About window links to the source code and to the author's website.

**Fixes.** A crash right after connecting (call lists were read while macOS was still setting up the link), a
recent-calls spinner that could run forever, and a number of accessibility improvements (contrast, VoiceOver
announcements, keyboard focus).

## 0.2.0 (2026-10-23)

- The menu bar icon brings an open call window to the front; Return ends a focused call.
- Larger text and higher contrast in the call windows.
- Hanging up shows its progress, and the call window closes once the phone has ended the call.

## 0.1.0 (2026-10-13)

The first public version.
- Incoming call banner with name, number and photo from your contacts, with Accept and Decline.
- Call window with the running time and End Call.
- Dial from the menu bar: a Phone-style popover with keypad and contact search.
- Phone number links (`tel:`, `callto:`) place the call on your phone after a confirmation.
- Missed call notifications, a global shortcut, launch at login, automatic reconnects.
- Native Liquid Glass design for macOS 26, light and dark, English and German.
