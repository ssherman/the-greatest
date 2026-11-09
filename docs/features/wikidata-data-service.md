# Wikidata Data Service

A read-only local copy of the parts of Wikidata the books code reads, built from Wikimedia's weekly
JSON dump and served over a small API. The service lives in `data-sources/` at the project root,
**not** inside `web-app/`.

Design: `docs/superpowers/specs/2026-11-08-wikidata-data-service-design.md`

**Status.** The pipeline, the API, the image and the compose services are written. The VM 150
tooling and the weekly refresh timer are written but nothing has been provisioned on the real server, no real dump has been built, and the Rails client
has not switched over. "Measured build" below is empty until Task 10 fills it.

## What it is

Live Wikidata cannot carry bulk work: the stage 2 rehearsals made no progress for days because
Wikidata's lag exceeded `maxlag=5`, and Wikimedia asks bulk readers to use the dumps. This service reads
the dump once a week, keeps the items the books code asks about, writes them as Parquet tables, and
answers exact lookups with DuckDB behind FastAPI. The local copy is the only Wikidata source: there is no
live fallback, not even for imports.

Same four boundaries as the other `data-sources/` services, enforced structurally:

1. **It never writes to Rails.** It returns entities; Rails decides what to store.
2. **It holds nothing that is not rebuildable from the dump** (CC0, no attribution constraint).
3. **It is never on a public request path.** Background jobs only.
4. **No covers, no public search, no serving.**

Decisions (Shane, 2026-11-08): books only, but stored generically so music and games are a config change
plus a rebuild, not new code; no live fallback; refresh weekly; the service gets VM 150 (8 vCPU, 12 GB),
with the API capped at 1 GB so it keeps serving while the build uses about 8 GB of DuckDB memory.
Nothing in a table name, column or route says "book".

## The kept set

Defined in `data-sources/src/wikidata/kept.yml`, not in code. For books:

- **Works and editions:** items whose type (`P31`) or form (`P7937`) is, or is a transitive subclass
  (`P279`) of, any of `work_roots` (mirrors `Wikidata::Work::WRITTEN_WORK_TYPES`) or the edition type
  `Q3331189`. The class closure is computed from the same dump. Scholarly articles (`Q13442814` and
  subclasses) are excluded; the `no_excluded_types` gate checks it.
- **People:** items typed as any of `person_types` (`Q5`, `Q61002`, `Q16017119`, `Q21070568`).
- **Anything a kept item points at** through the kept properties (countries, languages, genres, places,
  occupations).
- **Labels for every item in the dump** (English, `mul`, English description), so `/labels` answers for any
  QID without keeping the item.

Kept statements are the properties in `statement_properties` plus every property in `external_ids`.
Qualifiers and references are dropped; each statement keeps its rank, snaktype and datavalue. Labels,
descriptions and aliases are kept for `label_languages` (`en`, `mul`). Adding a property, a root or a
language is a `kept.yml` edit and a rebuild.

`external_ids` maps each indexed property to a normalizer. **P212 and P957 are one ISBN-13 namespace**:
both are stored as normalized ISBN-13 (digits only, ISBN-10 converted, bad check digits dropped), and a
lookup under either property searches both.

## The tables

Under `<root>/versions/<dump-date>/`, each sorted by its lookup key in 8,192-row groups (a Parquet lookup
pays for every row group it touches, whole):

| Table | Grain | Sorted by |
|---|---|---|
| `items` | one per kept QID: labels, descriptions, aliases, trimmed claims (JSON), `types`, `forms`, `subclass_of`, `enwiki_title`, `sitelink_count` | `qid` |
| `labels` | one per QID in the dump: `label_en`, `label_mul`, `description_en` | `qid` |
| `external_ids` | one per (property, normalized value, qid) | property, value, qid |
| `links` | one per (property, target, source), for reverse lookups (`P50`, `P800`) | property, target, source |
| `names` | one per (normalized name, qid), person-typed items, every language's labels and aliases | name, qid |
| `redirects` | one per merged QID: `from_qid`, `to_qid`, for every target that exists in the dump | from_qid |

Alongside them: `manifest.json` (dump date, counts, gate results, `gates_passed`, written last) and
`build_report.json`. `WikidataPaths` in `pipeline/paths.py` owns the layout.

**Redirects come from the SQL dumps**, not the JSON dump, which has none:
`wikidatawiki-latest-redirect.sql.gz` joined to `wikidatawiki-latest-page.sql.gz` (page id to QID). They are
produced about twice a month (Wikimedia's SQL dump cadence, observed 2026-11-08) and downloaded with each build.

## The API

JSON, read-only, port 8083. All routes are generic.

| Route | Answers |
|---|---|
| `GET /version` | dump date, `redirects_dump_date`, built-at, `gates_passed`, table counts, gate results |
| `POST /items` (at most 50 QIDs) | `items` keyed by the QID asked for (following redirects), plus `not_kept` and `missing` lists |
| `POST /labels` (at most 500) | `en`, `mul` and `description` per QID |
| `POST /by-external-id` (pairs, at most 500; `limit` caps the merged answer overall, not per property; default 10, max 100) | QIDs carrying any `property=value` pair; 422 for a property not indexed |
| `POST /linked-from` (targets, properties, optional `exclude_types`; `limit` default 5000, max 20000) | flat `rows: [[target, source, label], ...]` of the kept items linking to each target through `P50` and `P800`, plus `truncated`, which says whether `limit` cut the answer |
| `GET /names?q=` | person-typed items whose normalized label or alias equals the query, ranked by sitelink count; `limit` defaults to 10, max 100 |

`/items` separates two absences. **`not_kept`** means the QID exists in the dump but is outside the kept set;
**`missing`** means it is not in the dump at all. Callers must never drop a stored identifier on
`not_kept`. A QID merged into an unkept item is `not_kept`, never `missing`, which is why the `redirects`
table keeps redirects whose target is unkept.

`/names` is stricter than live `wbsearchentities`: it matches the whole normalized name (accents folded,
casefolded, punctuation to spaces), not a prefix or a fuzzy match.

Settings (env, forwarded by compose): `WD_DATA_ROOT` (`/data`), `WD_DATA_VERSION` (required; the API opens an
explicit `versions/<dump-date>` and never guesses), `WD_API_MEMORY_LIMIT` (512MB), `WD_API_TEMP_DIR`,
`WD_API_THREADS` (2).

**`redirects_dump_date`** is the date of the redirect SQL dump (the `Last-Modified` of the file the build
downloaded; `null` for a build from local files without `--redirects-dump-date`). That dump lives in
`latest/` and can be weeks older than the JSON dump, so a QID merged after it is `not_kept`/`missing` here
while Wikidata already redirects it. This is why Rails treats `missing` as "unknown", not "gone".

**Two things the API does not read from the artifact.** `external_id_kinds` (which properties
`/by-external-id` accepts, and their normalization kind) comes from the *image's* `kept.yml`, not from the
manifest. A `kept.yml` change therefore changes lookups only after the next weekly build has re-derived the
`external_ids` table, and an image deployed earlier than that build can accept a property whose table has no
rows. Second, a `PIPELINE_VERSION` bump makes the API refuse every older artifact (`VersionMismatch`) until
it is rebuilt; see "Deploying a PIPELINE_VERSION bump" below.

The API refuses to boot against a version with no manifest, `gates_passed` other than
true, a missing table, a symlinked version directory or a different `pipeline_version`.

## Building on dev

```bash
cd data-sources
uv sync --locked --extra wikidata
uv run python -m wikidata.pipeline.build --root /home/shane/wd-data --memory-limit 8GB --threads 6
```

With no `--dump` the build finds and downloads the newest dump and the redirect SQL. Options: `--dump` with
`--dump-date`, `--redirect-sql` and `--page-sql` to build from local files; `--keep-dump` (otherwise a
dump the build downloaded is deleted after a success); `--fixture` (skips the real-dump canaries, for the
test fixture).

Or through compose, which runs the same image with `/data` writable:

```bash
cd data-sources
WD_DATA_HOST=/home/shane/wd-data docker compose --profile wikidata run --rm wikidata-build
WD_DATA_VERSION=2026-11-05 docker compose --profile wikidata up -d wikidata   # then GET 127.0.0.1:8083/version
```

Facts the build depends on:

- **The dump's directory date is not its file date.** `entities/20261102/` holds
  `wikidata-20261105-all.json.gz`. The build's version, `versions/<date>` and `WD_DATA_VERSION` use the file
  date. Some directories hold only lexeme files, so discovery walks newest first until one holds the entity
  dump.
- **Two download connections.** Wikimedia allows two per IP; the download is two ranged parts, resumable,
  checked against the published md5. About 4.5 hours, measured on 2026-11-08 (two connections at about 4.8 MB/s each).
- **A verified existing dump is reused** on a rerun (md5 checked), so a failed distill does not re-download
  the whole dump.
- **A failed build keeps its evidence.** The tables are deleted, but `versions/<date>/` stays with
  `build_report.json` and a `manifest.json` carrying `gates_passed: false`. The refresh script reads the
  failed gate names from the report, and the date is never rebuilt in a loop. A version directory with no
  manifest is an unfinished build: neither passing nor failed.
- **Gates** run on the staged tables before anything is promoted: row counts within 15% of the previous
  passing version, real-dump canaries (Things Fall Apart, Chinua Achebe, known identifier and redirect
  lookups), no excluded types in `items`, and no `items` row group over 64 MB.
- **The build is two passes.** Pass one parses the dump in parallel into shards; DuckDB then computes the
  class closure and the kept set and writes the tables. DuckDB spills to `<root>/tmp`.

`python -m wikidata.pipeline.versions next-action|status|prune --root /data` is what the refresh timer asks:
whether the newest dump is already built or failed, which versions pass, and which to prune.

## Refresh on VM 150

VM 150 `wikidata` (8 vCPU, 12 GB, 400 GB data disk at `/srv/wd-data`) is provisioned by the home-server
tooling (`deployment/home-server`, `docs/features/home-server.md`). It is the same shape as the WorldCat VM:
`compose.wikidata.yml` sets the API to 1 GB (`WD_API_MEMORY_LIMIT=512MB`, 2 threads) and the build to
10 GB (`WD_BUILD_MEMORY_LIMIT=8GB`, 6 threads); `150.fw` allows only SSH from the LAN; the API listens on
loopback port 8083 and leaves through `cloudflared` (alias `wikidata`, `WIKIDATA_TUNNEL_TOKEN`).

`wikidata-refresh.timer` fires daily at 04:00 and 15 minutes after boot and runs
`guest/wikidata-refresh.sh`, which follows `ol-refresh.sh`:

1. Take the build lock (shared with deploy and the reboot check). If it is held, ping success with the message `deferred: lock held`
   and exit 0: the build runs for hours and a second timer firing must not start another.
2. Refuse if `/srv/wd-data` is not mounted.
3. `versions next-action` (run in `wikidata-build`): `skip ...` pings and exits; `build <date>` continues.
4. Create and enable an 8 GB swap file on the data disk (not in fstab).
5. `docker compose run --rm --no-deps -T wikidata-build`: the pipeline discovers, downloads (about 157 GB,
   roughly 4.5 hours) and builds. A non-zero exit with gates failed keeps the old version serving and the
   `fail` ping names the failed gates from `build_report.json`; a crash leaves an incomplete version that
   runs again next time.
6. On a passing build, write `current-version`, `compose up -d wikidata` with `WD_DATA_VERSION=<date>`, and
   poll `/version` until it reports that date. If it does not, write the old date back and ping `fail`; with
   no old version, remove `current-version` and stop the API.
7. `versions prune --keep 2`, then ping `success` with the date.

Healthchecks: `HC_WIKIDATA_HEARTBEAT` (the API answers), `HC_WIKIDATA_DEPLOY`, `HC_WIKIDATA_REFRESH`. Until
the first build passes there is no `current-version`, so the API is not started and the heartbeat is silent.

### Deploying a PIPELINE_VERSION bump

After a bump the API will not open the served artifact, and `versions next-action` still answers
`skip built <date>` because that manifest says `gates_passed: true`. To force a rebuild of the served date
on the VM, make it look unfinished and start the refresh by hand:

```bash
rm /srv/wd-data/versions/<served-date>/manifest.json
sudo systemctl start wikidata-refresh.service      # same script as the timer; takes the build lock
```

The build deletes and recreates `versions/<served-date>/`, so the API is down (Rails sees `Unavailable` and
reschedules) from the deploy until the new build passes, roughly half a day including the ~157 GB
download, which is not kept after a success. Schedule it for a quiet period. A build run by hand uses
`docker compose run --rm --no-deps -T wikidata-build` under the same lock the script takes.

### Weekly disk hygiene

The refresh script runs `versions prune --before <date>` right after `next-action` returns `build <date>`.
It deletes the downloaded dumps (and SQL files) of every earlier date and the failed or unfinished version
directories of earlier dates, so a failed week's 157 GB dump cannot accumulate on the 400 GB disk. It never
touches a passing version or the served one. The ordinary `prune --keep 2` still runs after a promotion.
Each build also clears `<root>/tmp` first, so DuckDB spill files from an OOM-killed build do not stay.

### A timed-out refresh can leave the build running

`wikidata-refresh.service` has `TimeoutStartSec=24h`. When systemd kills the script, it kills the
`docker compose run` client but not the build container, which dockerd owns. The script's build lock is then
released while a build is still running. Check with `docker ps` on the VM (look for the `wikidata-build`
container) and stop it before the next run:

```bash
docker ps --filter name=wikidata-build
docker stop <container-id>
```

## Measured build

Empty until Task 10: download time, build time, peak memory at 8 GB, table sizes and counts, largest row
group, API latency at 1 GB.
