# Music::SongRelationship

## Summary
Represents relationships between songs, such as covers, remixes, samples, and alternate versions. This is a self-referential join table that allows songs to be connected to related versions.

## Associations
- `belongs_to :song, class_name: "Music::Song"` — The original song
- `belongs_to :related_song, class_name: "Music::Song"` — The related song (cover, remix, etc.)
- `belongs_to :source_release, class_name: "Music::Release", optional: true` — Optional release where the related version appears

## Public Methods
None

## Validations
- `song` — presence
- `related_song` — presence
- `relation_type` — presence
- `song_id` — uniqueness (scope: [:related_song_id, :relation_type])
- Custom: `no_self_reference` — Prevents a song from relating to itself

## Scopes
- `covers` — Cover relationships
- `remixes` — Remix relationships
- `samples` — Sample relationships
- `alternates` — Alternate version relationships

## Constants
- `enum relation_type: { cover: 0, remix: 1, sample: 2, alternate: 3 }, prefix: true` — Available relationship types with prefix methods

## Callbacks
None

## Dependencies
None 