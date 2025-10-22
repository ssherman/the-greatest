# == Schema Information
#
# Table name: lists
#
#  id                    :bigint           not null, primary key
#  category_specific     :boolean
#  description           :text
#  estimated_quality     :integer          default(0), not null
#  formatted_text        :text
#  high_quality_source   :boolean
#  items_json            :jsonb
#  location_specific     :boolean
#  name                  :string           not null
#  num_years_covered     :integer
#  number_of_voters      :integer
#  raw_html              :text
#  simplified_html       :text
#  source                :string
#  status                :integer          default("unapproved"), not null
#  type                  :string           not null
#  url                   :string
#  voter_count_unknown   :boolean
#  voter_names_unknown   :boolean
#  year_published        :integer
#  yearly_award          :boolean
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#  musicbrainz_series_id :string
#  submitted_by_id       :bigint
#
# Indexes
#
#  index_lists_on_submitted_by_id  (submitted_by_id)
#
# Foreign Keys
#
#  fk_rails_...  (submitted_by_id => users.id)
#
module Music
  module Songs
    class List < ::List
      # Default ordering for list_items association
      has_many :list_items, -> { order(:position) }, foreign_key: :list_id, dependent: :destroy, inverse_of: :list

      # Scopes for eager loading list items with songs and all associations
      scope :with_songs_for_display, -> {
        includes(
          list_items: {
            listable: :artists
          }
        )
      }
    end
  end
end
