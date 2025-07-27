# Music::Release

## Summary
Represents a specific commercial release of an album (e.g., "Dark Side of the Moon - 2011 Remaster CD"). This tracks the format, release date, and track listing for each manifestation of an album.

## Associations
- `belongs_to :album, class_name: "Music::Album"` — The canonical album this release belongs to
- `has_many :tracks, -> { order(:medium_number, :position) }, class_name: "Music::Track"` — All tracks on this release, ordered by medium and position
- `has_many :songs, through: :tracks, class_name: "Music::Song"` — All songs included on this release
- `has_many :credits, as: :creditable, class_name: "Music::Credit"` — Polymorphic association for release-specific credits
- `has_many :identifiers, as: :identifiable, dependent: :destroy` — External identifiers for data import and deduplication

## Public Methods
None

## Validations
- `album` — presence
- `format` — presence

## Scopes
- `by_format(format)` — Filter releases by format (vinyl, cd, digital, etc.)
- `released_before(date)` — Releases with release_date <= given date
- `released_after(date)` — Releases with release_date >= given date

## Constants
- `enum format: { vinyl: 0, cd: 1, digital: 2, cassette: 3, blu_ray: 4 }, prefix: true` — Available release formats with prefix methods

## Callbacks
None

## Dependencies
None 