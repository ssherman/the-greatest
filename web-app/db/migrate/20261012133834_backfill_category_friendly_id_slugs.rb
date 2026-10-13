class BackfillCategoryFriendlyIdSlugs < ActiveRecord::Migration[8.1]
  # Calls the shared service so tests exercise the exact SQL that ships. It is
  # plain SQL with no model dependency beyond a connection, so later changes to
  # Category cannot break this migration.
  def up
    Categories::SlugHistoryBackfill.call
  end

  # The rows are indistinguishable from ones friendly_id writes itself afterwards,
  # and removing them would silently break renamed-category URLs, so no-op.
  def down
  end
end
