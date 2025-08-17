# Music::Release

## Summary
Represents a specific commercial release of an album (e.g., "Dark Side of the Moon - 2011 Remaster CD"). This tracks the format, release date, country, status, labels, and track listing for each manifestation of an album. Supports comprehensive release information imported from MusicBrainz.

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
- `status` — presence

## Scopes
- `by_format(format)` — Filter releases by format (vinyl, cd, digital, etc.)
- `by_status(status)` — Filter releases by status (official, promotion, bootleg, etc.)
- `by_country(country)` — Filter releases by country code
- `released_before(date)` — Releases with release_date <= given date
- `released_after(date)` — Releases with release_date >= given date

## Constants
- `enum format: { vinyl: 0, cd: 1, digital: 2, cassette: 3, other: 4 }, prefix: true` — Available release formats with prefix methods
- `enum status: { official: 0, promotion: 1, bootleg: 2, pseudo_release: 3, withdrawn: 4, expunged: 5, cancelled: 6 }, prefix: true` — Release status types with prefix methods

## Callbacks
None

## Dependencies
- DataImporters::Music::Release::Importer for automated imports from MusicBrainz 