module LegacyBooks
  class ActiveStorageAttachment < Record
    self.table_name = "active_storage_attachments"

    belongs_to :blob, class_name: "LegacyBooks::ActiveStorageBlob"
  end
end
