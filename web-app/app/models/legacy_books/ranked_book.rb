# == Schema Information
#
# Table name: ranked_books
#
#  id                       :bigint           not null, primary key
#  calculated_score         :decimal(, )
#  combined_position        :integer
#  score                    :decimal(10, 2)
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#  book_id                  :bigint           not null
#  ranking_configuration_id :bigint           not null
#
# Indexes
#
#  index_ranked_books_on_book_id_and_ranking_configuration_id  (book_id,ranking_configuration_id) UNIQUE
#  index_ranked_books_on_config_and_position                   (ranking_configuration_id,combined_position)
#  index_ranked_books_on_config_and_score                      (ranking_configuration_id,calculated_score)
#
# Foreign Keys
#
#  fk_rails_...  (book_id => books.id)
#  fk_rails_...  (ranking_configuration_id => ranking_configurations.id)
#
module LegacyBooks
  class RankedBook < Record
    self.table_name = "ranked_books"
  end
end
