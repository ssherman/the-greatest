# frozen_string_literal: true

# == Schema Information
#
# Table name: saved_searches
#
#  id               :bigint           not null, primary key
#  criteria         :jsonb            not null
#  description      :text
#  last_executed_at :datetime
#  name             :string
#  public           :boolean          default(FALSE), not null
#  result_count     :integer
#  type             :string           not null
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  user_id          :bigint           not null
#
# Indexes
#
#  index_saved_searches_on_public            (public) WHERE (public = true)
#  index_saved_searches_on_type_and_user_id  (type,user_id)
#  index_saved_searches_on_user_id           (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (user_id => users.id)
#
module Books
  class SavedSearch < ::SavedSearch
    # book_type has no column: legacy's four values are category data, so the
    # criterion resolves to a category. Reuses the migrator's legacy ids rather
    # than hardcoding new ones, because the categories table is shared across
    # domains and its ids were NOT preserved by the migration.
    BOOK_TYPE_LABELS = {
      0 => "Fiction",
      1 => "Nonfiction",
      2 => "Religion & Spirituality",
      3 => "Poetry"
    }.freeze

    def self.criteria_class_name
      "Books::SavedSearchCriteria"
    end

    def self.query_class_name
      "Books::SavedSearchQuery"
    end

    def self.criteria_class
      criteria_class_name.constantize
    end

    def self.query_class
      query_class_name.constantize
    end

    def self.ranking_configuration_class
      ::Books::RankingConfiguration
    end

    def self.excluded_list_type
      :read
    end

    def summary
      return "" if criteria.blank?

      parts = [
        BOOK_TYPE_LABELS[criteria["book_type"]],
        year_summary,
        ranked_summary,
        max_position_summary
      ]
      parts.compact.join(" · ")
    end

    private

    def year_summary
      gt = criteria["first_year_published_gt"]
      lt = criteria["first_year_published_lt"]
      return nil if gt.blank? && lt.blank?
      return "Published between #{gt} and #{lt}" if gt.present? && lt.present?
      return "Published after #{gt}" if gt.present?

      "Published before #{lt}"
    end

    def ranked_summary
      case criteria["ranked"]
      when "true" then "Ranked Books Only"
      when "false" then "Unranked Books Only"
      end
    end

    def max_position_summary
      position = criteria["max_ranked_position"]
      return nil if position.blank?

      "Top #{position} Ranked Books"
    end
  end
end
