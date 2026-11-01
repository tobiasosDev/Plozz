# FeatureTonightCore

Personal film suggestions ("Tonight"), ported from the Sichtung prototype. Pure
Swift: no UI, no direct networking. Sources are injected.

## Responsibility

- `TonightFilm`, `TonightGenre`, `TonightMerge`: one movie as the taste model
  sees it, merged across servers and Trakt by TMDb, IMDb or title and year.
- `TonightFeatures`, `TonightProfile`: interned feature ids (genres, genre
  pairs, keywords, synopsis words, directors, decade) and one taste centroid
  over the whole history, weighted by rating, rewatches and favorites.
- `TonightEngine` (actor): filters, scores, explains and spreads picks for a
  `TonightRequest`. Optional `TonightCandidateSource`s add films from outside
  the library; an optional `TonightReranker` may reorder the shortlist.
- `TonightReason`: structured reasons. The core never produces copy; the UI
  phrases every case through the string catalog.
- `TonightMemory`: the five decisions (save, later, never, seen, undo), shown
  history for rotation, seeds and quick ratings. A value type with explicit
  `now`, persisted per profile by `TonightFileStore`.
- `TonightQuickRate`: the "Sharpen Taste" round.
- `TonightLibraryLoader`: reads every movie library with `PageRequest.Detail.taste`
  and the profile's Trakt history, ratings and watchlist.
- `TonightModel`: the screen's observable state.

## Invariants

- **Facts only.** Reasons cite real ratings, favorites and viewings. An unrated
  single viewing is described carefully ("might suit"), never as liking.
- **Parental gate on every pick.** `TonightEngine(isAllowed:)` is checked during
  filtering and again before results are returned. Kids Profiles get no external
  candidates and only films on their own servers.
- **Quick ratings stay local.** They are never written to Trakt or a server.
- **Save goes through the shared watchlist.** Undo removes only an entry the
  same Save created.
- **Bounded memory.** 10,000 events within 180 days, five seed sets within 60
  days; permanent marks outlive the bounds. A corrupt state file is moved aside.
- **Scale.** Features are interned once per engine and the neighbour pass works
  on index arrays. Measure on device before enabling new defaults; see
  `docs/performance-lab.md`.
