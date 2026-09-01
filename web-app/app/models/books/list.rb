# == Schema Information
#
# Table name: lists
#
#  id                    :bigint           not null, primary key
#  activated_at          :datetime
#  auto_generated_kind   :integer
#  auto_generated_year   :integer
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
#  submitted_at          :datetime
#  submitter_email       :string
#  submitter_ip          :string
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
#  index_lists_on_activated_at                           (activated_at)
#  index_lists_on_submitted_at                           (submitted_at)
#  index_lists_on_submitted_by_id                        (submitted_by_id)
#  index_lists_on_type_and_auto_generated_kind_and_year  (type,auto_generated_kind,auto_generated_year) UNIQUE NULLS NOT DISTINCT WHERE (auto_generated_kind IS NOT NULL)
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
    # not against rows written by importers and migrations.
    def percentage_western
      items = list_items.by_listable_type("Books::Book").with_listable
      total = items.count
      return nil if total.zero?

      western_book_ids = ::Books::BookCountry
        .joins(:country)
        .merge(::Books::Country.with_label("western"))
        .select(:book_id)

      ((items.where(listable_id: western_book_ids).count.to_f / total) * 100).round(2)
    end
  end
end
