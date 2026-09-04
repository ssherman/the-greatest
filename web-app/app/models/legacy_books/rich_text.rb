# == Schema Information
#
# Table name: action_text_rich_texts
#
#  id          :bigint           not null, primary key
#  body        :text
#  name        :string           not null
#  record_type :string           not null
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#  record_id   :bigint           not null
#
# Indexes
#
#  index_action_text_rich_texts_uniqueness  (record_type,record_id,name) UNIQUE
#
module LegacyBooks
  # The legacy app's ActionText storage. The new app has no ActionText tables of
  # its own -- this exists only to read the 31 blog post bodies out.
  class RichText < Record
    self.table_name = "action_text_rich_texts"

    belongs_to :record, polymorphic: true
  end
end
