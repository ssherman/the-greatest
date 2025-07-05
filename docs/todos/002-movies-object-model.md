# The Greatest Movies — Database Schema (v0.1)

## Status
- **Status**: Not Started
- **Priority**: High
- **Created**: 2025-01-27
- **Started**: —
- **Completed**: —
- **Developer**: —

> **Stack**: PostgreSQL 16 · Rails 8 · Schema‑first migrations
>
> All tables use the Rails defaults `id:bigint` primary key and `created_at` / `updated_at` timestamps unless noted otherwise.

---

## Overview
Create a comprehensive data model for movies that supports the multi-domain architecture of The Greatest platform. The model should handle the complexity of film production, including directors, actors, crew, different release versions, and the various ways movies can be related to each other.

## Context
- Movies have different production structures than music (directors, producers, cast, crew)
- Multiple release versions exist (theatrical, director's cut, extended, international)
- Movies can be related through sequels, remakes, adaptations, and shared universes
- Need to support both individual films and series/franchises
- Must integrate with the existing multi-domain architecture

## Requirements
- [ ] Design comprehensive movie data model with proper namespacing
- [ ] Support for movies, directors, actors, and crew members
- [ ] Handle different release versions and formats
- [ ] Support for movie relationships (sequels, remakes, adaptations)
- [ ] Polymorphic credits system for various roles
- [ ] Integration with existing user lists and reviews system
- [ ] Proper indexing and performance considerations
- [ ] Comprehensive test coverage with fixtures
- [ ] Avo admin interface integration

## Technical Approach

### Core Models Structure
```
app/models/movies/
├── movie.rb              # Main movie entity
├── person.rb             # Directors, actors, crew (individuals)
├── release.rb            # Different versions/formats
├── credit.rb             # Polymorphic credits system
├── movie_relationship.rb # Sequels, remakes, adaptations
└── membership.rb         # Cast/crew assignments
```

### Key Design Decisions
1. **Person-centric approach**: All individuals (directors, actors, crew) as `Person` model
2. **Polymorphic credits**: Flexible role system for any movie-related work
3. **Release versions**: Support for different cuts, formats, and regional releases
4. **Relationship system**: Handle sequels, prequels, remakes, adaptations

## Dependencies
- Rails 8 with PostgreSQL 16
- FriendlyId for URL slugs
- Avo for admin interface
- Existing user authentication system
- Multi-domain routing setup (future task)

## Acceptance Criteria
- [ ] Can create and manage movies with full metadata
- [ ] Can assign directors, actors, and crew with proper roles
- [ ] Can handle different release versions (theatrical, director's cut, etc.)
- [ ] Can link movies through relationships (sequels, remakes, etc.)
- [ ] Can group movies into series/franchises
- [ ] All models have comprehensive validations and associations
- [ ] Full test coverage with realistic fixtures
- [ ] Admin interface works for all major models
- [ ] Performance is acceptable for typical queries

## Design Decisions

### Movie vs Film
- Use "Movie" as the primary term for consistency with domain naming
- Consider "Film" as an alternative display term if needed

### Person Model Approach
- Single `Person` model for all individuals (directors, actors, crew)
- Use polymorphic credits to assign roles
- This allows for complex career tracking and relationship mapping

### Release Version Strategy
- Separate `Release` model for different versions (theatrical, director's cut, extended)
- Each release can have different metadata, runtime, and credits
- Primary release marked for canonical data



### Credit System
- Polymorphic credits for maximum flexibility
- Support for both individual roles and grouped credits
- Position field for ordering within same role

---

## Detailed Table Definitions

### 1. `movies`

Represents the canonical movie work (e.g., *The Godfather*). Different versions live in `releases`.

| column           | type       | null? | default | notes                                    |
| ---------------- | ---------- | ----- | ------- | ---------------------------------------- |
| `id`             | bigint     | no    | —       | PK                                       |
| `title`          | string     | no    | —       | Movie title                              |
| `slug`           | string     | no    | —       | Unique URL slug (`index unique`)         |
| `description`    | text       | yes   | —       | Plot summary and context                 |
| `release_year`   | integer    | yes   | —       | 4‑digit year of **first** release        |
| `runtime_minutes`| integer    | yes   | —       | Canonical runtime in minutes             |
| `rating`         | integer    | yes   | —       | MPAA rating enum (`index`)               |

### Associations
- `has_many :releases`
- `has_many :credits, as: :creditable`
- `has_many :movie_relationships`            # outbound links
- `has_many :related_movies, through: :movie_relationships, source: :related_movie`

---

### 2. `people`

Represents **all** individuals involved in film production.

| column         | type         | null? | default | notes                                          |
| -------------- | ------------ | ----- | ------- | ---------------------------------------------- |
| `id`           | bigint       | no    | —       | PK                                             |
| `name`         | string       | no    | —       | Display name                                   |
| `slug`         | string       | no    | —       | Unique URL slug (`index unique`)               |
| `description`  | text         | yes   | —       | Biography/career overview                      |
| `born_on`      | date         | yes   | —       | Date of birth                                  |
| `died_on`      | date         | yes   | —       | Date of death (if applicable)                 |
| `country`      | string(2)    | yes   | —       | Country of origin (ISO‑3166 alpha‑2)          |
| `gender`       | integer      | yes   | —       | Gender enum (`index`)                          |

### Associations
- `has_many :credits, foreign_key: :person_id`
- `has_many :memberships, foreign_key: :person_id`

---

### 3. `releases`

A specific version/format of a movie (theatrical, director's cut, extended, etc.).

| column              | type      | null? | default | notes                                                                     |
| ------------------- | --------- | ----- | ------- | ------------------------------------------------------------------------- |
| `id`                | bigint    | no    | —       | PK                                                                        |
| `movie_id`          | bigint    | no    | —       | Parent movie (`fk → movies.id`, `index`)                                   |
| `release_name`      | string    | yes   | —       | e.g. "Director's Cut", "Extended Edition"                                 |
| `format`            | integer   | no    | `0`     | Enum: `0 = theatrical`, `1 = dvd`, `2 = blu_ray`, `3 = digital`, `4 = vhs` |
| `runtime_minutes`   | integer   | yes   | —       | Version-specific runtime                                                   |
| `release_date`      | date      | yes   | —       | Actual release date for this version                                       |
| `metadata`          | jsonb     | yes   | —       | Flexible storage for distributor, region, etc.                            |
| `is_primary`        | boolean   | no    | `false` | Mark as canonical version (`index`)                                        |

**Unique index**: `(movie_id, release_name, format)` to prevent exact duplicates.

### Associations
- `has_many :credits, as: :creditable`
- `has_many :memberships`

---

### 4. `credits` (polymorphic)

Stores *all* roles in film production.

| column            | type       | null? | default | notes                                  |
| ----------------- | ---------- | ----- | ------- | -------------------------------------- |
| `id`              | bigint     | no    | —       | PK                                     |
| `person_id`       | bigint     | no    | —       | (`fk → people.id`, `index`)             |
| `creditable_type` | string     | no    | —       | "Movie", "Release"                      |
| `creditable_id`   | bigint     | no    | —       | (`index together with type`)            |
| `role`            | integer    | no    | `0`     | Rails enum (`index`)                    |
| `position`        | integer    | yes   | —       | Ordering within same role               |
| `character_name`  | string     | yes   | —       | Character name (for actors)             |

**Role enum**: `director`, `producer`, `screenwriter`, `actor`, `actress`, `cinematographer`, `editor`, `composer`, `production_designer`, `costume_designer`, `makeup_artist`, `stunt_coordinator`, `visual_effects`, `sound_designer`, `casting_director`, `executive_producer`, `assistant_director`, `script_supervisor`

---

### 5. `memberships`

Join table for cast/crew assignments to specific releases.

| column        | type    | null? | default | notes                         |
| ------------- | ------- | ----- | ------- | ----------------------------- |
| `id`          | bigint  | no    | —       | PK                            |
| `release_id`  | bigint  | no    | —       | (`fk → releases.id`, `index`) |
| `person_id`   | bigint  | no    | —       | (`fk → people.id`, `index`)   |
| `role`        | integer | no    | —       | Role enum (same as credits)   |
| `position`    | integer | yes   | —       | Ordering within role          |
| `character_name` | string | yes   | —       | Character name (for actors)   |
| `notes`       | text    | yes   | —       | Additional context            |

**Unique index**: `(release_id, person_id, role, position)`

---

### 6. `movie_relationships`

Self‑referential join to link movies through various relationships.

| column              | type    | null? | default | notes                                                   |
| ------------------- | ------- | ----- | ------- | ------------------------------------------------------- |
| `id`                | bigint  | no    | —       | PK                                                      |
| `movie_id`          | bigint  | no    | —       | The *original* movie (`fk → movies.id`, `index`)        |
| `related_movie_id`  | bigint  | no    | —       | The sequel/remake/etc (`fk → movies.id`, `index`)       |
| `relation_type`     | integer | no    | `0`     | Enum: `0 = sequel`, `1 = prequel`, `2 = remake`, `3 = adaptation`, `4 = spin_off`, `5 = reboot` |
| `notes`             | text    | yes   | —       | Additional context about the relationship               |

**Unique index**: `(movie_id, related_movie_id, relation_type)`

### Associations (Rails)
```ruby
class MovieRelationship < ApplicationRecord
  enum relation_type: { sequel: 0, prequel: 1, remake: 2, adaptation: 3, spin_off: 4, reboot: 5 }

  belongs_to :movie
  belongs_to :related_movie, class_name: "Movie"
end
```

---

### 7. Enums & Look‑ups

```ruby
# movies.rating
{ g: 0, pg: 1, pg_13: 2, r: 3, nc_17: 4, unrated: 5 }



# releases.format
{ theatrical: 0, dvd: 1, blu_ray: 2, digital: 3, vhs: 4 }

# people.gender
{ male: 0, female: 1, non_binary: 2, other: 3 }

# credits.role & memberships.role
{ director: 0, producer: 1, screenwriter: 2, actor: 3, actress: 4, cinematographer: 5, editor: 6, composer: 7, production_designer: 8, costume_designer: 9, makeup_artist: 10, stunt_coordinator: 11, visual_effects: 12, sound_designer: 13, casting_director: 14, executive_producer: 15, assistant_director: 16, script_supervisor: 17 }

# movie_relationships.relation_type
{ sequel: 0, prequel: 1, remake: 2, adaptation: 3, spin_off: 4, reboot: 5 }
```

---

### 8. Essential Index Summary

- `movies.slug`, `people.slug` — unique slugs for routing
- `movies.release_year`, `movies.rating` — common filters
- `(movie_id, release_name, format)` on `releases`
- `(release_id, person_id, role, position)` on `memberships`
- Polymorphic pairs `(creditable_type, creditable_id)` and `(person_id, role)` on `credits`
- `(movie_id, related_movie_id, relation_type)` on `movie_relationships`
- `releases.is_primary` — for finding canonical versions

---

### 9. Foreign‑Key Diagram (textual)

```
movies 1——n releases 1——n memberships n——1 people
movies 1——n movie_relationships n——1 movies
people 1——n credits (polymorphic to movies / releases)
```

---

### Change‑log

- **v0.1 (2025‑01‑27)** — initial draft with core movie data model.

---

## Implementation Notes
*[This section will be filled out during/after implementation]*

### Approach Taken
*Describe how the feature was actually implemented.*

### Key Files Changed
*List all files that were modified or created.*

### Challenges Encountered
*Document any unexpected issues and how they were resolved.*

### Deviations from Plan
*Note any changes from the original technical approach and why.*

### Code Examples
```ruby
# Key code snippets that illustrate the implementation
```

### Testing Approach
*How the feature was tested, any edge cases discovered.*

### Performance Considerations
*Any optimizations made or needed.*

### Future Improvements
*Potential enhancements identified during implementation.*

### Lessons Learned
*What worked well, what could be done better next time.*

### Related PRs
*Link to any pull requests related to this implementation.*

### Documentation Updated
- [ ] Class documentation files updated
- [ ] API documentation updated
- [ ] README updated if needed 