module Services
  module BooksMigration
    # What one data_migration:sync run may write (spec §5): the legacy books,
    # authors and book_identifiers rows it brings over, and the redirects that
    # every other book or author id is routed through. Built by SyncPlan, read by
    # the migrators through their sync: argument.
    SyncScope = Struct.new(:book_ids, :author_ids, :identifier_ids, :redirects, keyword_init: true)
  end
end
