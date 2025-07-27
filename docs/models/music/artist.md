# Music::Artist

## Summary
Represents a musical artist, which can be either an individual person or a band. Core model for the music domain, used as the primary entity for credits, albums, and memberships.

## Associations
- `has_many :band_memberships, class_name: "Music::Membership", foreign_key: :artist_id` — All memberships where this artist is a band
- `has_many :memberships, class_name: "Music::Membership", foreign_key: :member_id` — All memberships where this artist is a person (member of a band)
- `has_many :albums, class_name: "Music::Album", foreign_key: :primary_artist_id` — Albums where this artist is the primary credited artist
- `has_many :credits, class_name: "Music::Credit"` — All credits (artistic/technical) associated with this artist
- `has_many :ai_chats, as: :parent, dependent: :destroy` — Polymorphic association for AI chat conversations
- `has_many :identifiers, as: :identifiable, dependent: :destroy` — External identifiers for data import and deduplication

## Public Methods

### `#person?`
Returns true if the artist is a person (not a band)
- Returns: Boolean

### `#band?`
Returns true if the artist is a band
- Returns: Boolean

### `#populate_details_with_ai!`
Populates artist details using AI services
- Returns: Services::Ai::Tasks::ArtistDetailsTask result object
- Side effects: Updates artist attributes with AI-generated data

## Validations
- `name` — presence
- `kind` — presence (must be either person or band)
- `country` — length is 2 (ISO-3166 alpha-2), allow blank
- Custom: `date_consistency` — Ensures only people have year_died and only bands have year_formed/year_disbanded

## Scopes
- `people` — All artists of kind person
- `bands` — All artists of kind band
- `active` — All bands that have not been disbanded (year_disbanded is nil)

## Constants
- `enum :kind, { person: 0, band: 1 }` — Distinguishes between people and bands

## Callbacks
- None

## Dependencies
- FriendlyId gem for slug generation and lookup from name
- Services::Ai::Tasks::ArtistDetailsTask for AI-powered data enrichment 