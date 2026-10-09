module Services
  module BooksMigration
    # What one data_migration:sync run may write (spec §5): the legacy books,
    # authors and book_identifiers rows it brings over, and the redirects that
    # every other book or author id is routed through. books_watermark is the
    # books watermark this run advances to: a legacy book above it has not been
    # copied yet, so user data on it waits for a later run (spec §6). Built by
    # SyncPlan, read by the migrators through their sync: argument.
    SyncScope = Struct.new(:book_ids, :author_ids, :identifier_ids, :redirects, :books_watermark, keyword_init: true)
  end
end
