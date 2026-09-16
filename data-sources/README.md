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

Building an artifact is documented in `docs/features/open-library-data-service.md`
at the project root.

## Running the API

The service is **never on a public request path** -- it is a private backend
that Rails (or anything else internal) reaches over plain HTTP. Run it
alongside the Rails app, or on trusted infrastructure only.

**Local**, against an artifact already built at `OL_DATA_ROOT`:

    OL_DATA_ROOT=/home/shane/ol-data OL_DATA_VERSION=2026-07-31 \
      uv run uvicorn --factory openlibrary.api.main:factory --host 0.0.0.0 --port 8080

`OL_DATA_VERSION` is required (an explicit version directory, never a
symlink -- see `deps.py`). `OL_API_MEMORY_LIMIT` (default `8GB`) and
`OL_API_TEMP_DIR` (default the system temp dir) are optional.

**Docker**, via the compose file in this directory:

    docker compose up -d api                              # serves :8080, artifact mounted read-only
    docker compose --profile build run --rm build          # rebuild an artifact; artifact mounted writable

`OL_DATA_HOST` (default `/home/shane/ol-data`) picks the artifact root on the
host; `OL_DATA_VERSION` (default `2026-07-31`) picks the version directory.
Override either on the command line: `OL_DATA_VERSION=2026-08-31 docker
compose up -d api`.

**Endpoints** (full response shapes and measured latencies are in
`docs/features/open-library-data-service.md`, "Service, measured"):

    GET  /version                          curl localhost:8080/version
    GET  /works/{key}                      curl localhost:8080/works/OL81205W
    GET  /works/{key}/editions             curl localhost:8080/works/OL81205W/editions
    GET  /authors/{key}                    curl localhost:8080/authors/OL19964A
    GET  /authors/{key}/works              curl 'localhost:8080/authors/OL19964A/works?limit=10'
    GET  /identifiers/{type}/{value}       curl localhost:8080/identifiers/isbn13/9780141181722
    POST /works/batch                      curl -X POST localhost:8080/works/batch \
                                              -H 'content-type: application/json' -d '{"keys":["OL81205W"]}'
    POST /authors/batch                    curl -X POST localhost:8080/authors/batch \
                                              -H 'content-type: application/json' -d '{"keys":["OL19964A"]}'
    POST /resolve                          curl -X POST localhost:8080/resolve \
                                              -H 'content-type: application/json' \
                                              -d '{"title":"The Great Gatsby","author_names":["F. Scott Fitzgerald"],"year":1925}'
