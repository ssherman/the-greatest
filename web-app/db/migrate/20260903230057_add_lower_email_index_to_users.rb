class AddLowerEmailIndexToUsers < ActiveRecord::Migration[8.1]
  # CONCURRENTLY cannot run inside a transaction. users is ~242 MB / ~69.5k
  # rows, so a plain CREATE INDEX would hold a SHARE lock and block every
  # write to the table -- including sign-ins on live music and games -- for
  # the duration of the build.
  disable_ddl_transaction!

  # users.email has no index of any kind. Both email lookups on the auth path
  # are expressed as LOWER(email) = ?, so today each one sequentially scans
  # the whole table:
  #
  #   Seq Scan on users  (cost=0.00..16030.42) (actual time=21.496..21.496)
  #     Filter: (lower((email)::text) = '...'::text)
  #     Rows Removed by Filter: 69495
  #     Buffers: shared hit=2653 read=12335
  #
  # That runs on every sign-in (UserAuthenticationService#find_user) and every
  # /auth/check_provider call, which the two-step email->password widget hits
  # while the visitor is still typing.
  #
  # The expression must be written to match the one the planner sees. email is
  # a varchar, so Postgres records the predicate as lower((email)::text); a
  # bare LOWER(email) here produces exactly that, which is why the index is
  # usable by the existing queries without touching them.
  #
  # NOT unique, deliberately. The table currently holds 33 groups / 69 rows of
  # duplicate emails, from two separate causes -- a signup race (validates
  # :email, uniqueness is a read-then-write check that cannot hold without a
  # DB constraint; median creation gap within a group is 0.2s) and
  # UserMigrator's upsert_all, which bypasses validations by design. A unique
  # index would fail on today's data, and worse, it would abort
  # data_migration:all mid-run on every future run, on the database music and
  # games are live on. The unique constraint has to come after the duplicates
  # stop being generated, not before.
  def up
    add_index :users, "LOWER(email)", name: "index_users_on_lower_email",
      algorithm: :concurrently, if_not_exists: true
  end

  def down
    remove_index :users, name: "index_users_on_lower_email",
      algorithm: :concurrently, if_exists: true
  end
end
