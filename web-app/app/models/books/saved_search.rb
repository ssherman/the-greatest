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

    # category, language, and country criteria are omitted from summary: naming
    # them requires a database lookup, and the index page renders this for every
    # one of a user's searches, so keeping those lookup-free avoids an N+1 there.
    # book_type and book_length don't need that tradeoff -- both are plain enums,
    # so they render through a label lookup with no query involved.
    def summary
      return "" if criteria.blank?

      parts = [
        ::Books::BookType.label(criteria["book_type"]),
        book_length_summary,
        year_summary,
        ranked_summary,
        max_position_summary
      ]
      parts.compact.join(" · ")
    end

    private

    # Stored criteria is an Array of book_length ints (e.g. [1, 2]) for every
    # migrated row, but Array() also tolerates a bare scalar, matching legacy's
    # own `is_a?(Array) ? ... : [value]` normalization.
    def book_length_summary
      lengths = Array(criteria["book_length"]).compact
      return nil if lengths.blank?

      labels = lengths.map { |length| ::Books::Book.book_lengths.key(length).to_s.titleize }
      "#{labels.join(", ")} Length"
    end

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
