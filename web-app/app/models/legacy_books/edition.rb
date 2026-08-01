# == Schema Information
#
# Table name: editions
#
#  id               :bigint           not null, primary key
#  book_binding     :integer
#  description      :text
#  flat_identifiers :text             is an Array
#  identifiers      :jsonb
#  last_refreshed   :datetime
#  metadata         :jsonb
#  popularity       :integer
#  publication_year :integer
#  title            :string
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  book_id          :bigint           not null
#  ol_edition_id    :string
#
# Indexes
#
#  index_editions_on_book_binding      (book_binding)
#  index_editions_on_book_id           (book_id)
#  index_editions_on_flat_identifiers  (flat_identifiers) USING gin
#  index_editions_on_identifiers       (identifiers) USING gin
#  index_editions_on_popularity        (popularity)
#
# Foreign Keys
#
#  fk_rails_...  (book_id => books.id)
#
module LegacyBooks
  class Edition < Record
    self.table_name = "editions"
  end
end
