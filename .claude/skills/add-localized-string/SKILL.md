---
name: add-localized-string
description: Add or change a user-facing string in Pickup with English and German text and a translator comment in the String Catalog. Use whenever UI text, menu items, alerts, accessibility labels or Info.plist usage descriptions change.
---

# Add a localized string (English and German)

Development language is English; every string ships in English **and** German. `scripts/check-localization.sh`
fails the build when a key has no translated `de` value, no translator comment, mismatching placeholders, or when
code uses a key that is not in the catalog.

1. **Use it in code** through the catalog, never as a plain `String`:
   - SwiftUI: `Text("Decline")`, `Button("Accept") { … }` (these take a `LocalizedStringKey`);
   - elsewhere: `String(localized: "Connected to \(phoneName)", comment: "…")`;
   - variable parts are placeholders (`%@`, `%lld`), never concatenation: `"Call %@"`, not `"Call " + name`;
   - format numbers, durations and dates with the user's locale (existing helpers: `PhoneNumberFormat`,
     `CallDurationFormat`).
2. **Add the key** to `App/Resources/Localizable.xcstrings` (Info.plist texts: `App/Resources/InfoPlist.xcstrings`),
   following the existing entries:
   ```json
   "Call %@": {
     "comment": "Button in the contact row. %@ is the contact's name.",
     "extractionState": "manual",
     "localizations": {
       "en": { "stringUnit": { "state": "translated", "value": "Call %@" } },
       "de": { "stringUnit": { "state": "translated", "value": "%@ anrufen" } }
     }
   }
   ```
   - The comment says where the text appears and what each placeholder holds.
   - German: natural, Apple-style wording ("Einstellungen …", "Ablehnen", "Annehmen"); same placeholders as English.
3. **Check:** `scripts/check-localization.sh` (also part of `scripts/verify.sh --quick`).
4. **Layout:** German is often 30 % longer. For changed views, ask the maintainer to look at them in German
   (`-AppleLanguages "(de)"`) or check the UI-test screenshots.
5. Remove keys you made unused (the check lists them as "stale").
