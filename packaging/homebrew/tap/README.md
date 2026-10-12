# macx/homebrew-tap

Homebrew tap for the official builds of [Pickup for Mac](https://github.com/macx/pickup) – Android calls on macOS.

```bash
brew install --cask macx/tap/pickup   # the fully qualified name also trusts this cask (Homebrew 6+ tap trust)
brew upgrade --cask pickup
```

If you tapped first (`brew tap macx/tap`), trust the cask once with `brew trust --cask macx/tap/pickup`.
Requires macOS 26 or newer on Apple silicon. Only signed and notarised releases are published here.

`brew uninstall --cask pickup` removes the app; `brew uninstall --zap --cask pickup` also removes its preferences and
logs.

## How this tap is updated

`Casks/pickup.rb` is generated. Do not edit it by hand: the release workflow of `macx/pickup` renders it from
`packaging/homebrew/Casks/pickup.rb` with `scripts/update-cask.sh` after each release has been signed, notarised and
published, and pushes the change here (or opens a pull request). The CI of this repository runs `brew style` and
`brew audit` on every push and pull request.

The cask installs only the signed and notarised DMG from the official GitHub Releases, checked against its SHA-256.

## Licence

The cask file is MIT-licensed like Pickup's source code. The name "Pickup" and its icon are not; see
[TRADEMARKS.md](https://github.com/macx/pickup/blob/main/TRADEMARKS.md).
