# == Schema Information
#
# Table name: countries
#
#  id          :bigint           not null, primary key
#  book_count  :integer
#  description :text
#  labels      :string           is an Array
#  name        :string
#  slug        :string
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#
# Indexes
#
#  index_countries_on_book_count  (book_count)
#  index_countries_on_labels      (labels) USING gin
#  index_countries_on_name        (name)
#  index_countries_on_slug        (slug) UNIQUE
#
module LegacyBooks
  class Country < Record
    self.table_name = "countries"
  end
end
