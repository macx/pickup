# Trademarks and brand use

The **source code** of Pickup is licensed under the MIT licence (`LICENSE`). The MIT licence covers copyright in the
code only. It does **not** grant any rights to the name **"Pickup"** (as the name of this app, including "Pickup for
Mac"), the Pickup **icon** and **menu bar glyph**, or the other files in `docs/brand/` and `App/Resources/Pickup.icon`
(together: "the Pickup marks"). The Pickup marks belong to David Eiken.

This policy exists so that people can tell the official app apart from modified copies. It is not meant to stop
anyone from using, studying, changing or sharing the code.

## Official builds

- Official builds of Pickup are published **only** from the official repository, <https://github.com/macx/pickup>:
  as GitHub Releases (a DMG and a ZIP, signed with David Eiken's Developer ID, notarised by Apple, with SHA-256
  checksums) and through the Homebrew cask `macx/tap/pickup`, which installs those same release files.
- Anything else, including builds from forks, mirrors, other download sites or other package repositories, is not an
  official build, even if it is unmodified.

## Forks and modified versions

If you distribute a fork or any modified version (source or binary), you must:

1. **Rename it.** Do not call it "Pickup", "Pickup for Mac" or a confusingly similar name (for example "Pickup Pro",
   "Pickup+", "PickupX").
2. **Replace the icon and the menu bar glyph** with your own artwork, and remove `docs/brand/`.
3. **Change the bundle identifier** (`dev.eiken.pickup`) and the URL scheme names that identify the app, so your
   build does not replace or impersonate the official app on users' Macs.
4. **Not suggest endorsement.** Do not imply that your version is official, approved or supported by David Eiken.

You may state factually that your project is "based on Pickup" or "a fork of Pickup (https://github.com/macx/pickup)".
You must keep the MIT copyright notice, as the licence requires.

Building the unmodified source for your own personal use, on your own Mac, is fine and needs no permission.

## Referring to Pickup (fair use)

You may, without asking:

- use the name "Pickup" to refer to the official app, for example in articles, reviews, tutorials, comparisons,
  package indexes and "works with" statements;
- show the **unmodified** icon next to such a reference or a link to the official repository or release;
- take and publish screenshots of the official app.

Please:

- do not alter the icon (colours, shape, proportions) or combine it with your own marks;
- do not use the name or icon as part of your own product name, logo, domain name or social media handle;
- do not use the marks in a way that suggests sponsorship or endorsement.

## Third-party parts

The Pickup mark is derived from the Lucide "phone-call" icon, which is available under the ISC licence
(`THIRD_PARTY_NOTICES.md`). This policy does not restrict anyone's rights in the original Lucide icon.

## Questions

For anything not covered here, open an issue in the official repository before you use the marks.
