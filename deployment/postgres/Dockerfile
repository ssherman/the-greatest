# deployment/postgres/Dockerfile -- the database server image: the official image plus pgBackRest.
# Spec: docs/superpowers/specs/2026-11-06-postgres-server-design.md §4.
# Pinned by digest, because a floating tag once swapped a system library under the old server and
# silently changed text sorting. Digest of postgres:18.6-trixie read from the registry on 2026-11-06.
# To upgrade: `docker pull postgres:18.X-trixie`, copy its digest from `docker inspect`, update the
# date, and rebuild. Debian trixie is the release with a matching PGDG pgBackRest; the archive line below names it too.
FROM postgres:18.6-trixie@sha256:e3d24f6906d0760bf4da0dae872415391ededefad23fd471c47dc53b0ddf3c42

# The base image already carries the PGDG apt repository. pgBackRest pinned to an exact version.
# The libraries that decide text sorting are held first, so no dependency can ever replace them
# silently (the failure that made the old server's sort order change). Measured on 2026-11-06:
# installing pgbackrest adds only pgbackrest and libssh2-1t64, and its package creates
# /var/log/pgbackrest and /var/spool/pgbackrest owned by postgres.
# PGDG's current index keeps only recent versions, so an exact pin alone would stop resolving and break a
# disaster rebuild. Its archive repo keeps every version, signed with the image's own PGDG key. The archive
# redirects to https, so ca-certificates comes first, and pgBackRest needs that bundle to verify S3 anyway.
# --error-on=any makes an unreachable source fail the build: by default apt only warns and carries on without it.
# Checked on 2026-11-07 by building with the current repo removed.
RUN apt-mark hold libc6 locales libicu76 \
 && apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates \
 && echo 'deb [ signed-by=/usr/local/share/keyrings/postgres.gpg.asc ] https://apt-archive.postgresql.org/pub/repos/apt trixie-pgdg-archive main' \
      >/etc/apt/sources.list.d/pgdg-archive.list \
 && apt-get update --error-on=any \
 && apt-get install -y --no-install-recommends pgbackrest=2.60.0-1.pgdg13+1 \
 && rm -rf /var/lib/apt/lists/*
