#!/usr/bin/env bash
#
# PreToolUse(Bash) guard: refuse commands that destroy the development database.
#
# Why this exists: on 2026-07-13 an agent ran
#   bin/rails runner 'ActiveRecord::FixtureSet.create_fixtures("test/fixtures", [...])'
# against DEVELOPMENT to inspect fixture definitions. create_fixtures TRUNCATES every
# table it names before inserting. It wiped music_albums, music_artists, lists and
# list_items, and cost a full night of re-migrating the books data (which lives only
# in dev — it is not in production).
#
# Reads the hook payload on stdin, emits a PreToolUse permission decision on stdout.
# Exit 0 always; the JSON carries the decision.
set -uo pipefail

payload="$(cat)"
cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')"

[ -n "$cmd" ] || { printf '{}\n'; exit 0; }

deny() {
  jq -cn --arg reason "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
}

# An explicit test-environment target is always safe — the test DB is disposable
# and is rebuilt by db:test:prepare.
if printf '%s' "$cmd" | grep -Eq 'RAILS_ENV=test|\bdb:test:prepare\b'; then
  printf '{}\n'
  exit 0
fi

# bin/refresh-dev-db.sh is a deliberate, guarded restore path with its own
# confirmation prompt. Not the accident class this guard is for.
if printf '%s' "$cmd" | grep -q 'refresh-dev-db\.sh'; then
  printf '{}\n'
  exit 0
fi

if printf '%s' "$cmd" | grep -Eq 'create_fixtures|FixtureSet'; then
  deny 'BLOCKED: create_fixtures TRUNCATES every table it names. Run against development it destroys real data — this already cost a full night of re-migration once.

To READ fixture definitions, read the YAML directly:
  sed -n "/^fixture_name:/,/^$/p" test/fixtures/<file>.yml

If you genuinely need fixtures loaded, target the test database explicitly:
  RAILS_ENV=test bin/rails db:fixtures:load'
fi

if printf '%s' "$cmd" | grep -Eq '\bdb:(drop|reset|setup|schema:load|truncate_all|purge)\b'; then
  deny 'BLOCKED: this rake task drops or truncates the database, and no RAILS_ENV=test was given.

The books data exists ONLY in this dev database — it is not in production, and rebuilding it from the legacy DB takes hours.

If you meant the test database:  RAILS_ENV=test bin/rails <task>
If you meant to restore dev from production:  bin/refresh-dev-db.sh'
fi

# Destructive ActiveRecord calls inside a `rails runner` one-liner.
if printf '%s' "$cmd" | grep -Eq '(rails|rake)[^|]*runner' \
   && printf '%s' "$cmd" | grep -Eq '\.(delete_all|destroy_all|update_all)\b|\bdelete_by\b|\bdestroy_by\b'; then
  deny 'BLOCKED: bulk delete/update via `rails runner` against the development database.

The books data exists ONLY in dev and takes hours to rebuild from the legacy DB.

If this is genuinely intended, ask the user to run it themselves (they can prefix the command with ! in the prompt), or target the test DB with RAILS_ENV=test.'
fi

# Raw SQL destruction against a non-test database.
if printf '%s' "$cmd" | grep -Eiq 'drop[[:space:]]+database|truncate[[:space:]]+table|truncate[[:space:]]+[a-z_]+|delete[[:space:]]+from' \
   && ! printf '%s' "$cmd" | grep -Eq '_test\b|the_greatest_test'; then
  deny 'BLOCKED: raw SQL DROP/TRUNCATE/DELETE FROM against a non-test database.

If this targets the test database, name it explicitly (…_test).
Otherwise ask the user to run it themselves — they can prefix the command with ! in the prompt.'
fi

printf '{}\n'
exit 0
