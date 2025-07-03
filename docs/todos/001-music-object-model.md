# The Greatest Music — Database Schema (v0.3)

> **Stack**: PostgreSQL 16 · Rails 8 · Schema‑first migrations
>
> All tables use the Rails defaults `id:bigint` primary key and `created_at` / `updated_at` timestamps unless noted otherwise.

---

## 1. `artists`

Represents **both** individual people *and* groups/bands.

| column         | type         | null? | default | notes                                          |
| -------------- | ------------ | ----- | ------- | ---------------------------------------------- |
| `id`           | bigint       | no    | —       | PK                                             |
| `name`         | string       | no    | —       | Display name                                   |
| `slug`         | string       | no    | —       | Unique URL slug (`index unique`)               |
| `description`  | text         | yes   | —       | Biography/career overview                      |
| `kind`         | integer      | no    | `0`     | Rails enum: `0 = person`, `1 = band` (`index`) |
| `country`      | string(2)    | yes   | —       | ISO‑3166 alpha‑2                               |
| `born_on`      | date         | yes   | —       | Only for persons                               |
| `died_on`      | date         | yes   | —       | Only for persons                               |
| `formed_on`    | date         | yes   | —       | Only for bands                                 |
| `disbanded_on` | date         | yes   | —       | Only for bands                                 |

### Associations

- `has_many :band_memberships, class_name: "Membership", foreign_key: :artist_id`
- `has_many :memberships, foreign_key: :member_id`
- `has_many :albums, foreign_key: :primary_artist_id`

---

## 2. `memberships`

Join table recording a person's tenure in a band.

| column      | type   | null? | default | notes                              |
| ----------- | ------ | ----- | ------- | ---------------------------------- |
| `id`        | bigint | no    | —       | PK                                 |
| `artist_id` | bigint | no    | —       | The **band** (`fk → artists.id`)   |
| `member_id` | bigint | no    | —       | The **person** (`fk → artists.id`) |
| `joined_on` | date   | yes   | —       |                                    |
| `left_on`   | date   | yes   | —       |                                    |

**Indexes**: `(artist_id, member_id, joined_on)` composite unique to avoid duplicates.

---

## 3. `albums`

Canonical work (e.g. *Black Celebration*). Commercial manifestations live in `releases`.

| column              | type    | null? | default | notes                                    |
| ------------------- | ------- | ----- | ------- | ---------------------------------------- |
| `id`                | bigint  | no    | —       | PK                                       |
| `title`             | string  | no    | —       |                                          |
| `slug`              | string  | no    | —       | Unique (`index unique`)                  |
| `description`       | text    | yes   | —       | Album overview and context               |
| `primary_artist_id` | bigint  | no    | —       | Main credit (`fk → artists.id`, `index`) |
| `release_year`      | integer | yes   | —       | 4‑digit year of **first** release        |

### Associations

- `has_many :releases`
- `has_many :songs, through: :releases`
- `has_many :credits, as: :creditable`

---

## 4. `releases`

A specific commercial release (format, bonus tracks, remaster…).

| column           | type      | null? | default | notes                                                                     |
| ---------------- | --------- | ----- | ------- | ------------------------------------------------------------------------- |
| `id`             | bigint    | no    | —       | PK                                                                        |
| `album_id`       | bigint    | no    | —       | Parent work (`fk → albums.id`, `index`)                                   |
| `release_name`   | string    | yes   | —       | e.g. "2007 Remaster" (was `edition_name`)                                 |
| `format`         | integer   | no    | `0`     | Enum: `0 = vinyl`, `1 = cd`, `2 = digital`, `3 = cassette`, `4 = blu_ray` |
| `metadata`       | jsonb     | yes   | —       | Flexible storage for label, catalog_number, region, etc.                  |
| `release_date`   | date      | yes   | —       | Actual street date                                                        |

**Unique index**: `(album_id, release_name, format)` to prevent exact duplicates.

### Associations

- `has_many :tracks, -> { order(:disc_number, :position) }`
- `has_many :songs, through: :tracks`
- `has_many :credits, as: :creditable`

---

## 5. `songs`

Musical compositions independent of any one recording.

| column          | type       | null? | default | notes                                                             |
| --------------- | ---------- | ----- | ------- | ----------------------------------------------------------------- |
| `id`            | bigint     | no    | —       | PK                                                                |
| `title`         | string     | no    | —       |                                                                   |
| `slug`          | string     | no    | —       | Unique (`index unique`)                                           |
| `description`   | text       | yes   | —       | Song background, meaning, and context                             |
| `duration_secs` | integer    | yes   | —       | Canonical runtime                                                 |
| `isrc`          | string(12) | yes   | —       | International Std. Recording Code (`index unique where not null`) |
| `lyrics`        | text       | yes   | —       | Optional plaintext                                                |

### Associations

- `has_many :tracks`
- `has_many :releases, through: :tracks`
- `has_many :albums, through: :releases`
- `has_many :credits, as: :creditable`
- `has_many :song_relationships`            # outbound links
- `has_many :related_songs, through: :song_relationships, source: :related_song`

---

## 6. `tracks`

Join table for the track‑list of a release.

| column        | type    | null? | default | notes                         |
| ------------- | ------- | ----- | ------- | ----------------------------- |
| `id`          | bigint  | no    | —       | PK                            |
| `release_id`  | bigint  | no    | —       | (`fk → releases.id`, `index`) |
| `song_id`     | bigint  | no    | —       | (`fk → songs.id`, `index`)    |
| `disc_number` | integer | no    | `1`     | 1‑based Disc #                |
| `position`    | integer | no    | —       | 1‑based Track # within disc   |
| `length_secs` | integer | yes   | —       | Release‑specific runtime      |
| `notes`       | text    | yes   | —       | e.g. "2019 mix"               |

**Unique index**: `(release_id, disc_number, position)`

---

## 7. `credits` (polymorphic)

Stores *all* artistic & technical roles.

| column            | type       | null? | default | notes                                  |
| ----------------- | ---------- | ----- | ------- | -------------------------------------- |
| `id`              | bigint     | no    | —       | PK                                     |
| `artist_id`       | bigint     | no    | —       | (`fk → artists.id`, `index`)           |
| `creditable_type` | string     | no    | —       | "Song", "Album", "Release"             |
| `creditable_id`   | bigint     | no    | —       | (`index together with type`)           |
| `role`            | integer    | no    | `0`     | Rails enum (`index`)                   |
| `position`        | integer    | yes   | —       | Ordering within same role              |

**Role enum**: `writer`, `composer`, `lyricist`, `arranger`, `performer`, `vocalist`, `guitarist`, `bassist`, `drummer`, `keyboardist`, `producer`, `engineer`, `mixer`, `mastering`, `featured`, `guest`, `remixer`, `sampler`

---

## 8. `song_relationships`

Self‑referential join to link a song to **other** versions such as covers, remixes, live renditions, samples, or alternate mixes.

| column              | type    | null? | default | notes                                                   |
| ------------------- | ------- | ----- | ------- | ------------------------------------------------------- |
| `id`                | bigint  | no    | —       | PK                                                      |
| `song_id`           | bigint  | no    | —       | The *original* song  (`fk → songs.id`, `index`)         |
| `related_song_id`   | bigint  | no    | —       | The cover/remix/etc (`fk → songs.id`, `index`)          |
| `relation_type`     | integer | no    | `0`     | Enum: `0 = cover`, `1 = remix`, `2 = sample`, `3 = alt` |
| `source_release_id` | bigint  | yes   | —       | Optional: where the related version appears             |

**Unique index**: `(song_id, related_song_id, relation_type)`

### Associations (Rails)

```ruby
class SongRelationship < ApplicationRecord
  enum relation_type: { cover: 0, remix: 1, sample: 2, alternate: 3 }

  belongs_to :song
  belongs_to :related_song, class_name: "Song"
  belongs_to :source_release, class_name: "Release", optional: true
end
```

---

## 9. Enums & Look‑ups

```ruby
# artist.kind
{ person: 0, band: 1 }

# releases.format
{ vinyl: 0, cd: 1, digital: 2, cassette: 3, blu_ray: 4 }

# credits.role
{ writer: 0, composer: 1, lyricist: 2, arranger: 3, performer: 4, vocalist: 5, guitarist: 6, bassist: 7, drummer: 8, keyboardist: 9, producer: 10, engineer: 11, mixer: 12, mastering: 13, featured: 14, guest: 15, remixer: 16, sampler: 17 }

# song_relationships.relation_type
{ cover: 0, remix: 1, sample: 2, alternate: 3 }
```

Additional enums (e.g. `genre`) can live in lookup tables for flexibility.

---

## 10. Essential Index Summary

- `artists.slug`, `albums.slug`, `songs.slug` — unique slugs for routing
- `(album_id, release_name, format, region)` on `releases`
- `(release_id, disc_number, position)` on `tracks`
- Polymorphic pairs `(creditable_type, creditable_id)` and `(artist_id, role)` on `credits`
- `(song_id, related_song_id, relation_type)` on `song_relationships`

---

## 11. Foreign‑Key Diagram (textual)

```
artists 1——n memberships n——1 artists
artists 1——n albums 1——n releases 1——n tracks n——1 songs
songs   1——n song_relationships n——1 songs
artists 1——n credits (polymorphic to songs / albums / releases)
```

---

### Change‑log

- **v0.4 (2025‑07‑02)** — added `description` fields to `artists`, `albums`, and `songs` tables.
- **v0.3 (2025‑07‑02)** — renamed `album_editions` to `releases` (and associated column & FK names).
- **v0.2 (2025‑07‑02)** — removed external ID and artwork columns; added `song_relationships`.
- **v0.1 (2025‑07‑02)** — initial public draft.

---

*Questions or edge‑cases?* Feel free to add comments in the PR or ping @author in Slack.

