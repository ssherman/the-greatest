class AddOneGrantPerUserIndexToMemberships < ActiveRecord::Migration[8.1]
  def change
    # Pre-flight check. This does NOT avert the outage: `db:prepare` runs
    # inside `bin/docker-entrypoint` (`#!/bin/bash -e`), so a raise here fails
    # the container's startup exactly as a `PG::UniqueViolation` from
    # `add_index` below would. `restart: unless-stopped` still crash-loops the
    # web container either way. All this buys is a legible message in that
    # crash-loop log instead of a raw constraint error -- naming the
    # offending (user_id, source) pairs and the fix, rather than leaving the
    # operator to reverse-engineer a PG::UniqueViolation with no row context.
    #
    # The real operational mitigation is to run this same query against
    # production BEFORE merging, not to rely on this check catching it at
    # deploy time. Cheap and read-only: the table is ~127 rows, so this is a
    # single fast GROUP BY, not a scan worth guarding further.
    #
    # up_only, not a bare call: `execute` is not automatically invertible, so
    # a plain call here would make this migration raise IrreversibleMigration
    # on `db:rollback` even though nothing about the check itself needs
    # reverting -- rolling back just needs to drop the index, which add_index
    # below already supports on its own.
    up_only do
      offenders = execute(<<~SQL).to_a
        SELECT user_id, source, COUNT(*)
        FROM memberships
        WHERE source <> 0 AND user_id IS NOT NULL
        GROUP BY user_id, source
        HAVING COUNT(*) > 1
      SQL

      if offenders.any?
        described = offenders.map { |row| "user_id=#{row["user_id"]} source=#{row["source"]}" }.join(", ")
        raise <<~MSG
          Cannot add index_memberships_one_grant_per_user_per_source: existing rows
          violate the one-grant-per-user-per-source invariant: #{described}.
          Resolve by revoking or reattaching the duplicate membership row(s) for
          each (user_id, source) pair above before re-running this migration.
        MSG
      end
    end

    # source <> 0 is "not :stripe". A user may hold any number of Stripe
    # subscriptions -- that is Stripe's business -- but at most one legacy
    # early-supporter grant and at most one comp. This is what makes both
    # MembershipMigrator and the admin comp form idempotent structurally
    # rather than by convention.
    #
    # user_id IS NOT NULL is required, not decorative: an unattached row is a
    # customer we could not map, and several of those must be able to coexist.
    #
    # No `algorithm: :concurrently`: the table is ~127 rows and the lock this
    # takes is milliseconds -- not worth the extra migration-file split
    # `:concurrently` requires (it cannot run inside a transactional DDL
    # migration).
    add_index :memberships, [:user_id, :source],
      unique: true,
      where: "source <> 0 AND user_id IS NOT NULL",
      name: "index_memberships_one_grant_per_user_per_source"
  end
end
