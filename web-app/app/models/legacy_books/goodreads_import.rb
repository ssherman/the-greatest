module LegacyBooks
  # A legacy member's Goodreads upload (the legacy app's GoodreadsImport, with
  # has_one_attached :file). Read by the replay loader (Goodreads import spec
  # §12.1). Status is the legacy enum's integer; STATUSES names it without an
  # enum, which would introspect a table the test database does not have.
  class GoodreadsImport < Record
    self.table_name = "goodreads_imports"

    STATUSES = {0 => "not_started", 1 => "pending", 2 => "complete", 3 => "failed"}.freeze

    has_one :file_attachment, -> { where(record_type: "GoodreadsImport", name: "file") },
      class_name: "LegacyBooks::ActiveStorageAttachment", foreign_key: :record_id
  end
end
