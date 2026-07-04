module LegacyBooks
  # Read-only base for the legacy Greatest Books database (a Rails multi-db
  # `replica`). Never written to — the migration only reads from here.
  #
  # `connects_to` is skipped in test: Rails' parallel-test-worker database
  # renaming (ActiveRecord::TestDatabases.create_and_load_schema) suffixes
  # every configured database, including replicas, but never creates them for
  # replicas (database_tasks? is false) — so a real per-worker
  # legacy_books_test_N database would never exist. No test ever queries
  # these models for real (see docs/superpowers/plans, Task 1's Global
  # Constraints: "No test legacy database is required or created"), so in
  # test these classes simply fall back to ApplicationRecord's normal
  # connection, unused.
  class Record < ApplicationRecord
    self.abstract_class = true
    connects_to database: {writing: :legacy_books, reading: :legacy_books} unless Rails.env.test?

    def readonly?
      true
    end
  end
end
