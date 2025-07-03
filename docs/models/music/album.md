# Music::Album

## Summary
Represents a canonical album/work (e.g., "Dark Side of the Moon"). This is the conceptual album, while commercial manifestations are tracked in the `Music::Release` model.

## Associations
- `belongs_to :primary_artist, class_name: "Music::Artist"` — The main credited artist for the album
- `has_many :releases, class_name: "Music::Release"` — All commercial releases of this album (CD, vinyl, digital, etc.)
- `has_many :credits, as: :creditable, class_name: "Music::Credit"` — Polymorphic association for all artistic and technical credits

## Public Methods
None

## Validations
- `title` — presence
- `slug` — presence, uniqueness
- `primary_artist` — presence
- `release_year` — numericality (integer only), allow nil

## Scopes
None

## Constants
None

## Callbacks
None

## Dependencies
- FriendlyId gem for slug generation and lookup 