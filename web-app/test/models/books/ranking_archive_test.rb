require "test_helper"

# == Schema Information
#
# Table name: ranking_archives
#
#  id                              :bigint           not null, primary key
#  captured_at                     :datetime         not null
#  description                     :text
#  hidden                          :boolean          default(FALSE), not null
#  item_ids                        :bigint           default([]), not null, is an Array
#  items_count                     :integer          default(0), not null
#  name                            :string           not null
#  period                          :date
#  positions                       :integer          default([]), not null, is an Array
#  scores                          :decimal(10, 2)   default([]), not null, is an Array
#  slug                            :string           not null
#  type                            :string           not null
#  created_at                      :datetime         not null
#  updated_at                      :datetime         not null
#  legacy_ranking_configuration_id :integer
#  ranking_configuration_id        :bigint
#
# Indexes
#
#  index_ranking_archives_on_config_and_period                (ranking_configuration_id,period) UNIQUE WHERE (period IS NOT NULL)
#  index_ranking_archives_on_legacy_config                    (legacy_ranking_configuration_id) UNIQUE WHERE (legacy_ranking_configuration_id IS NOT NULL)
#  index_ranking_archives_on_ranking_configuration_id         (ranking_configuration_id)
#  index_ranking_archives_on_type_and_hidden_and_captured_at  (type,hidden,captured_at)
#  index_ranking_archives_on_type_and_slug                    (type,slug) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (ranking_configuration_id => ranking_configurations.id) ON DELETE => nullify
#
module Books
  class RankingArchiveTest < ActiveSupport::TestCase
    test "item_type is Books::Book" do
      assert_equal "Books::Book", Books::RankingArchive.item_type
    end

    test "item_class is Books::Book" do
      assert_equal ::Books::Book, ranking_archives(:books_january_2027).item_class
    end
  end
end
