# == Schema Information
#
# Table name: authors
#
#  id                     :bigint           not null, primary key
#  ai_description         :text
#  alternative_names      :string           is an Array
#  auto_imported          :boolean          default(FALSE), not null
#  birth_year             :integer
#  calculated_score       :decimal(, )
#  death_year             :integer
#  description            :text
#  description_source     :string
#  description_source_url :string
#  family_name            :string
#  gender                 :integer
#  given_name             :string
#  initials               :string
#  name                   :string           not null
#  nationality_text       :string
#  normalized_name        :string
#  ol_photo_ids           :integer          default([]), is an Array
#  search_string          :tsvector
#  transliterated_name    :string
#  use_initials           :boolean          default(FALSE), not null
#  wikipedia_url          :string
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#  ol_author_id           :string
#  ol_cover_id            :integer
#
# Indexes
#
#  index_authors_on_calculated_score  (calculated_score)
#  index_authors_on_gender            (gender)
#  index_authors_on_name              (name) USING gin
#  index_authors_on_nationality_text  (nationality_text)
#  index_authors_on_ol_author_id      (ol_author_id)
#  index_authors_on_search_string     (search_string) USING gin
#
module LegacyBooks
  class Author < Record
    self.table_name = "authors"
  end
end
