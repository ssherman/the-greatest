class AddWikipediaTitleIndexToExternalRecords < ActiveRecord::Migration[8.1]
  # CONCURRENTLY cannot run inside a transaction. Every author step reads
  # and writes external_records, so a plain CREATE INDEX would block them
  # for the build.
  disable_ddl_transaction!

  # Services::Books::Authors::WikipediaLead finds a stored lead by the
  # language and title inside its payload; without this every lookup scans
  # every stored lead. Partial: only wikipedia rows (source 2) carry those
  # keys. Raw SQL, because add_index has no form for two expressions.
  def up
    execute <<~SQL
      CREATE INDEX CONCURRENTLY IF NOT EXISTS index_external_records_on_wikipedia_language_and_title
      ON external_records ((payload ->> 'language'), (payload ->> 'title'))
      WHERE source = 2
    SQL
  end

  def down
    execute "DROP INDEX CONCURRENTLY IF EXISTS index_external_records_on_wikipedia_language_and_title"
  end
end
