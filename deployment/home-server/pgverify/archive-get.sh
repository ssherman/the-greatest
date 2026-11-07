#!/bin/sh
# deployment/home-server/pgverify/archive-get.sh <wal file> <destination>
# The restored cluster's restore_command (forced on the command line in compose.pgverify.yml).
# pgBackRest's archive-get exits 1 when the segment is not in the archive, and another code (42 for a
# read error, 55 for a missing control file, ...) when the fetch itself failed. Postgres treats any exit
# from 1 to 125 as "no more WAL" and finishes recovery on a new timeline, so a failed read would pass for
# a complete restore. Only "not found" is passed through as 1; everything else exits above 125, which
# makes Postgres abort recovery instead.
pgbackrest --stanza=main archive-get "$1" "$2"
rc=$?
case "$rc" in
  0 | 1) exit "$rc" ;;
  *) exit 200 ;;
esac
