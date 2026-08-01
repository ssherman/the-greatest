# == Schema Information
#
# Table name: book_identifiers
#
#  id              :bigint           not null, primary key
#  identifier      :string
#  identifier_type :integer
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  book_id         :bigint           not null
#
# Indexes
#
#  index_book_identifiers_on_book_id                   (book_id)
#  index_book_identifiers_on_identifier_type_and_book  (identifier,identifier_type,book_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (book_id => books.id)
#
module LegacyBooks
  class BookIdentifier < Record
    self.table_name = "book_identifiers"
  end
end
