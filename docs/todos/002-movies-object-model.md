# The Greatest Movies — Database Schema (v0.1)

## Status
- **Status**: In Progress
- **Priority**: High
- **Created**: 2025-01-27
- **Started**: 2025-07-05
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
- [x] Design comprehensive movie data model with proper namespacing
- [x] Support for movies, directors, actors, and crew members
- [x] Handle different release versions and formats
- [ ] Support for movie relationships (sequels, remakes, adaptations)
- [x] Polymorphic credits system for various roles
- [ ] Integration with existing user lists and reviews system
- [x] Proper indexing and performance considerations
- [x] Comprehensive test coverage with fixtures
- [ ] Avo admin interface integration

## Technical Approach

### Core Models Structure
```
app/models/movies/
├── movie.rb              # ✅ Main movie entity
├── person.rb             # ✅ Directors, actors, crew (individuals)
├── release.rb            # ✅ Different versions/formats
├── credit.rb             # ✅ Polymorphic credits system
├── movie_relationship.rb # ⏳ Sequels, remakes, adaptations
└── membership.rb         # ⏳ Cast/crew assignments
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
- [x] Can create and manage movies with full metadata
- [x] Can assign directors, actors, and crew with proper roles
- [x] Can handle different release versions (theatrical, director's cut, etc.)
- [ ] Can link movies through relationships (sequels, remakes, etc.)
- [ ] Can group movies into series/franchises
- [x] All models have comprehensive validations and associations
- [x] Full test coverage with realistic fixtures
- [ ] Admin interface works for all major models
- [x] Performance is acceptable for typical queries

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

### Approach Taken
The implementation followed the domain-driven design approach with proper namespacing under `Movies::`. Each model was implemented incrementally, starting with the core entities (Movie, Person, Release) and then adding the polymorphic Credits system. The implementation prioritized:

1. **Proper namespacing** - All models under `Movies::` module
2. **Comprehensive validations** - Business rules enforced at model level
3. **Polymorphic associations** - Flexible credit system for movies and releases
4. **Performance optimization** - Proper indexes and scopes
5. **Test coverage** - 100% test coverage with realistic fixtures

### Key Files Changed
**Models Created:**
- `app/models/movies/movie.rb` - Core movie entity with ratings and metadata
- `app/models/movies/person.rb` - Individuals involved in film production
- `app/models/movies/release.rb` - Different versions/formats of movies
- `app/models/movies/credit.rb` - Polymorphic credits system

**Migrations:**
- `db/migrate/20250705172655_create_movies_credits.rb` - Credits table with proper indexes

**Tests:**
- `test/models/movies/movie_test.rb` - Movie model tests
- `test/models/movies/person_test.rb` - Person model tests  
- `test/models/movies/release_test.rb` - Release model tests
- `test/models/movies/credit_test.rb` - Comprehensive credit system tests

**Fixtures:**
- `test/fixtures/movies/movies.yml` - Movie test data
- `test/fixtures/movies/people.yml` - Person test data
- `test/fixtures/movies/releases.yml` - Release test data
- `test/fixtures/movies/credits.yml` - Credit test data

**Documentation:**
- `docs/models/movies/movie.md` - Movie model documentation
- `docs/models/movies/person.md` - Person model documentation
- `docs/models/movies/release.md` - Release model documentation
- `docs/models/movies/credit.md` - Credit model documentation

### Challenges Encountered
1. **Fixture naming conventions** - Had to use namespaced fixture helper methods (`movies_movies`, `movies_people`, etc.) for namespaced test classes
2. **Polymorphic associations** - Required careful setup of foreign key constraints and indexes
3. **Test isolation** - Some tests needed to clear existing data to avoid interference from fixtures
4. **Enum validation** - Rails enums don't allow invalid values, requiring different testing approach

### Deviations from Plan
- **Enum naming**: Used `release_format` instead of `format` in Release model for clarity
- **Validation approach**: Added custom validation methods for complex business rules (e.g., `died_on_after_born_on`)
- **Scope implementation**: Added more specific scopes than originally planned for better query performance

### Code Examples
```ruby
# Polymorphic credits system
class Movies::Credit < ApplicationRecord
  belongs_to :person, class_name: "Movies::Person"
  belongs_to :creditable, polymorphic: true
  
  enum :role, {
    director: 0, producer: 1, screenwriter: 2, actor: 3, actress: 4,
    # ... 18 total roles
  }
  
  scope :by_role, ->(role) { where(role: role) }
  scope :for_movie, ->(movie) { where(creditable: movie) }
  scope :for_release, ->(release) { where(creditable: release) }
end

# Movie with credits and releases
class Movies::Movie < ApplicationRecord
  has_many :releases, class_name: "Movies::Release", dependent: :destroy
  has_many :credits, as: :creditable, class_name: "Movies::Credit", dependent: :destroy
  
  enum :rating, {g: 0, pg: 1, pg_13: 2, r: 3, nc_17: 4, unrated: 5}
end
```

### Testing Approach
- **Comprehensive test coverage**: 17 tests for Credits model alone
- **Realistic fixtures**: Used actual movie data (The Godfather, Shawshank Redemption, etc.)
- **Namespaced testing**: All tests properly namespaced under `Movies::`
- **Polymorphic testing**: Tests for both movie and release credits
- **Validation testing**: All business rules tested with edge cases
- **Scope testing**: All custom scopes tested for correct filtering and ordering

### Performance Considerations
- **Database indexes**: Added indexes on polymorphic associations and role filtering
- **Efficient queries**: Scopes designed for common query patterns
- **Proper associations**: Used `dependent: :destroy` for data integrity
- **Validation optimization**: Custom validations only run when needed

### Future Improvements
- **Memberships model**: Still needed for release-specific cast/crew assignments
- **Movie relationships**: Still needed for sequels, remakes, adaptations
- **Admin interface**: Avo integration for content management
- **User integration**: Connect to existing user lists and reviews system
- **Search optimization**: OpenSearch integration for full-text search

### Lessons Learned
- **Namespacing consistency**: Important to maintain consistent naming across models, tests, and fixtures
- **Polymorphic design**: Very flexible but requires careful consideration of indexes and constraints
- **Test data management**: Fixtures need to be realistic and properly isolated
- **Documentation value**: Having comprehensive documentation makes implementation much smoother

### Related PRs
- Implementation completed in single session with comprehensive testing

### Documentation Updated
- [x] Class documentation files updated
- [ ] API documentation updated (not applicable yet)
- [ ] README updated if needed (not applicable yet) 