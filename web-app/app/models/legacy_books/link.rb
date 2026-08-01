# == Schema Information
#
# Table name: links
#
#  id          :bigint           not null, primary key
#  description :text
#  name        :string
#  url         :string           not null
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#  book_id     :bigint           not null
#  user_id     :bigint           not null
#
# Indexes
#
#  index_links_on_book_id  (book_id)
#  index_links_on_user_id  (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (book_id => books.id)
#  fk_rails_...  (user_id => users.id)
#
module LegacyBooks
  class Link < Record
    self.table_name = "links"
  end
end
