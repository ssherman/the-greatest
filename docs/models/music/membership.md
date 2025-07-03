# Music::Membership

## Summary
Represents a person's membership in a band. This is a join table that records when someone joined and left a band, allowing for tracking of band lineups over time.

## Associations
- `belongs_to :artist, class_name: "Music::Artist"` — The band that the person is/was a member of
- `belongs_to :member, class_name: "Music::Artist"` — The person who is/was a member of the band

## Public Methods
None

## Validations
- `artist_id` — presence
- `member_id` — presence
- Custom: `artist_is_band` — Ensures the artist is a band (not a person)
- Custom: `member_is_person` — Ensures the member is a person (not a band)
- Custom: `member_not_same_as_artist` — Prevents a band from being a member of itself
- Custom: `date_consistency` — Ensures left_on date is not before joined_on date

## Scopes
- `active` — Memberships where the person has not left (left_on is nil)
- `current` — Alias for active
- `former` — Memberships where the person has left (left_on is not nil)

## Constants
None

## Callbacks
None

## Dependencies
None 