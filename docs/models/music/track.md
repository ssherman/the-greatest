# Music::Track

## Summary
Represents a track on a specific release. This is a join table that connects songs to releases and defines their position and medium number within the release's track listing.

## Associations
- `belongs_to :release, class_name: "Music::Release"` — The release this track appears on
- `belongs_to :song, class_name: "Music::Song"` — The song that this track represents

## Public Methods
None

## Validations
- `release` — presence
- `song` — presence
- `medium_number` — presence, numericality (integer, greater than 0)
- `position` — presence, numericality (integer, greater than 0)
- `length_secs` — numericality (integer, greater than 0), allow nil

## Scopes
- `ordered` — Tracks ordered by medium_number, then position
- `on_medium(num)` — Tracks on a specific medium number

## Constants
None

## Callbacks
None

## Dependencies
None 