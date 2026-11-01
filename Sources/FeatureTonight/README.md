# FeatureTonight

The "Tonight" screen: the request as Plozz browse pills, the selected pick as a
hero with its reason and evidence, the other picks as a poster row, and the
"Sharpen Taste" quick rating round.

## Responsibility

- `TonightView`: binds a `TonightModel` to Plozz components (`BrowseQueryControls`,
  `FallbackAsyncImage`, native tvOS menus, card buttons). Playback and details
  are delegated to the shell through `onPlay` and `onOpenDetail`, so they behave
  exactly like everywhere else.
- `TonightQuickRateView`: one watched, unrated film at a time.
- `TonightCopy`: every user-visible sentence, as whole sentences per case so
  translations can reorder freely.

## Invariants

- No provider access. Artwork comes from the shell's `TonightArtworkResolver`.
- Source copy is English and lives in the app string catalog; run
  `tools/l10n-sync.py` after changing it.
