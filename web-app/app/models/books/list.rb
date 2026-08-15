# == Schema Information
#
# Table name: lists
#
#  id                    :bigint           not null, primary key
#  activated_at          :datetime
#  category_specific     :boolean
#  creator_specific      :boolean
#  description           :text
#  estimated_quality     :integer          default(0), not null
#  high_quality_source   :boolean
#  items_json            :jsonb
#  location_specific     :boolean
#  name                  :string           not null
#  num_years_covered     :integer
#  number_of_voters      :integer
#  raw_content           :text
#  simplified_content    :text
#  source                :string
#  source_country_origin :string
#  status                :integer          default(0), not null
#  type                  :string           not null
#  url                   :string
#  voter_count_estimated :boolean
#  voter_count_unknown   :boolean
#  voter_names_unknown   :boolean
#  wizard_state          :jsonb
#  year_published        :integer
#  yearly_award          :boolean
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#  musicbrainz_series_id :string
#  submitted_by_id       :bigint
#
# Indexes
#
#  index_lists_on_activated_at     (activated_at)
#  index_lists_on_submitted_by_id  (submitted_by_id)
#
# Foreign Keys
#
#  fk_rails_...  (submitted_by_id => users.id)
#
module Books
  class List < ::List
    # Percentage of the list's books whose country of origin carries the
    # "western" label, 0.0-100.0, or nil when the list has no resolved book
    # items -- an empty list cannot be western-biased.
    #
    # The listable_type filter is redundant against ListItem's validation but
    # not against rows written by importers and migrations, and it lets the
    # query use index_list_items_on_listable.
    def percentage_western
      items = list_items.where(listable_type: "Books::Book").where.not(listable_id: nil)
      total = items.count
      return nil if total.zero?

      western_book_ids = Books::BookCountry
        .joins(:country)
        .merge(Books::Country.with_label("western"))
        .select(:book_id)

      ((items.where(listable_id: western_book_ids).count.to_f / total) * 100).round(2)
    end
  end
end
