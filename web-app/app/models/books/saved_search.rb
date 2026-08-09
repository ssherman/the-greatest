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

    def self.filter_labels_class_name
      "Books::SavedSearchFilterLabels"
    end

    def self.filter_labels_class
      filter_labels_class_name.constantize
    end

    def self.ranking_configuration_class
      ::Books::RankingConfiguration
    end

    def self.excluded_list_type
      :read
    end

    # category, language, and country criteria are omitted: naming them requires
    # a database lookup, and the index page renders this for every one of a
    # user's searches, so keeping it lookup-free avoids an N+1 there. book_type
    # and book_length don't need that tradeoff -- both are plain enums.
    #
    # Every value is read through criteria_object rather than the raw hash, so
    # a form-created search storing "0" renders the same as a migrated row
    # storing 0.
    def summary
      parts = [
        ::Books::BookType.label(criteria_object.book_type),
        book_length_summary,
        year_summary,
        ranked_summary,
        max_position_summary
      ]
      parts.compact.join(" · ")
    end

    private

    def book_length_summary
      lengths = criteria_object.book_length
      return nil if lengths.empty?

      labels = lengths.map { |length| ::Books::Book.book_lengths.key(length).to_s.titleize }
      "#{labels.join(", ")} Length"
    end

    def year_summary
      gt = criteria_object.first_year_published_gt
      lt = criteria_object.first_year_published_lt
      return nil if gt.nil? && lt.nil?
      return "Published between #{gt} and #{lt}" if gt && lt
      return "Published after #{gt}" if gt

      "Published before #{lt}"
    end

    def ranked_summary
      case criteria_object.ranked
      when :ranked then "Ranked Books Only"
      when :unranked then "Unranked Books Only"
      end
    end

    def max_position_summary
      position = criteria_object.max_ranked_position
      return nil if position.nil?

      "Top #{position} Ranked Books"
    end
  end
end
