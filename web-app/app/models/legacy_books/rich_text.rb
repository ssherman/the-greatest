module LegacyBooks
  # The legacy app's ActionText storage. The new app has no ActionText tables of
  # its own -- this exists only to read the 31 blog post bodies out.
  class RichText < Record
    self.table_name = "action_text_rich_texts"

    belongs_to :record, polymorphic: true
  end
end
