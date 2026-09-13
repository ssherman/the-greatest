# data-sources

Backend book-data sources for The Greatest. Each source distills public bulk data
into an immutable Parquet artifact and serves it over a small read-only HTTP API.
Nothing here writes to the Rails database.

- `src/common/` — shared, versioned normalizer, schemas, comparators, build gates.
- `src/openlibrary/` — the Open Library source: pipeline, matcher, API, evaluation set.

## Commands

    uv sync --locked          # install; FAILS if uv.lock does not match pyproject.toml
    uv run pytest             # tests (fixture data only, never the real artifact)
    uv run ruff check .
    uv run ruff format --check .

Building an artifact and running the API are documented in
`docs/features/open-library-data-service.md` at the project root.
