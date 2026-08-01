# == Schema Information
#
# Table name: books
#
#  id                             :bigint           not null, primary key
#  ai_answers                     :jsonb
#  ai_generated_description       :text
#  alternate_title_1              :string
#  alternate_titles               :string           default([]), is an Array
#  authors_data                   :jsonb
#  authors_search_string          :tsvector
#  auto_imported                  :boolean          default(FALSE), not null
#  book_length                    :integer
#  book_type                      :integer          default(0), not null
#  description                    :text
#  description_source_name        :string
#  description_source_url         :string
#  first_year_published           :integer
#  first_year_published_estimated :boolean          default(FALSE)
#  goodreads_description          :text
#  incorrect_olwork               :boolean          default(FALSE), not null
#  normalized_title               :string
#  origin_countries               :string           is an Array
#  page_range                     :string
#  primary_amazon_url             :string
#  primary_bookshop_org_url       :string
#  primary_image_large_key        :string
#  primary_image_medium_key       :string
#  primary_image_small_key        :string
#  search_string                  :tsvector
#  series                         :boolean          default(FALSE), not null
#  series_name                    :string
#  series_number                  :integer
#  sort_title                     :string
#  sub_title                      :string
#  summary                        :text
#  title                          :string           not null
#  transliterated_title           :string
#  use_description                :integer          default(0), not null
#  word_count                     :integer
#  written_in_ancient_times       :boolean          default(FALSE)
#  created_at                     :datetime         not null
#  updated_at                     :datetime         not null
#  goodreads_id                   :string
#  ol_cover_id                    :integer
#  ol_work_id                     :string
#  original_language_id           :bigint
#
# Indexes
#
#  index_books_on_authors_search_string     (authors_search_string) USING gin
#  index_books_on_book_length               (book_length)
#  index_books_on_book_type                 (book_type)
#  index_books_on_goodreads_id              (goodreads_id)
#  index_books_on_ol_work_id                (ol_work_id)
#  index_books_on_origin_countries          (origin_countries) USING gin
#  index_books_on_original_language_id      (original_language_id)
#  index_books_on_primary_amazon_url        (primary_amazon_url)
#  index_books_on_primary_bookshop_org_url  (primary_bookshop_org_url)
#  index_books_on_primary_image_medium_key  (primary_image_medium_key)
#  index_books_on_search_string             (search_string) USING gin
#  index_books_on_sort_title                (sort_title)
#  index_books_on_title                     (title)
#  index_books_on_word_count                (word_count)
#  index_books_on_written_in_ancient_times  (written_in_ancient_times)
#
# Foreign Keys
#
#  fk_rails_...  (original_language_id => languages.id)
#
module LegacyBooks
  class Book < Record
    self.table_name = "books"
  end
end
