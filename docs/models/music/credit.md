# Music::Credit

## Summary
Represents artistic and technical credits for songs, albums, and releases. This is a polymorphic model that can credit artists for various roles on any creditable entity.

## Associations
- `belongs_to :artist, class_name: "Music::Artist"` — The artist being credited
- `belongs_to :creditable, polymorphic: true` — The entity being credited (Song, Album, or Release)

## Public Methods
None

## Validations
- `artist` — presence
- `creditable` — presence
- `role` — presence

## Scopes
- `by_role(role)` — Credits with a specific role
- `ordered` — Credits ordered by position, then id
- `for_songs` — Credits for songs only
- `for_albums` — Credits for albums only
- `for_releases` — Credits for releases only

## Constants
- `enum role: { writer: 0, composer: 1, lyricist: 2, arranger: 3, performer: 4, vocalist: 5, guitarist: 6, bassist: 7, drummer: 8, keyboardist: 9, producer: 10, engineer: 11, mixer: 12, mastering: 13, featured: 14, guest: 15, remixer: 16, sampler: 17 }` — Available credit roles

## Callbacks
None

## Dependencies
None 