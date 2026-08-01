# == Schema Information
#
# Table name: lists
#
#  id                       :bigint           not null, primary key
#  ai_generated_description :text
#  books_json               :jsonb
#  category_specific        :boolean
#  description              :text
#  estimated_quality        :integer          default(0)
#  formatted_text           :text
#  high_quality_source      :boolean
#  location_specific        :boolean
#  lp_css_selector_mappings :text
#  name                     :string           not null
#  number_of_voters         :integer
#  percentage_western       :float
#  ranked                   :boolean
#  raw_html                 :text
#  source                   :string
#  status                   :integer          default(0)
#  unformatted_text         :text
#  url                      :string
#  voter_count_unknown      :boolean
#  voter_names_unknown      :boolean
#  year_published           :integer
#  yearly_award             :boolean
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#  submitted_by_id          :bigint
#
# Indexes
#
#  index_lists_on_estimated_quality  (estimated_quality)
#  index_lists_on_name               (name)
#  index_lists_on_source             (source)
#  index_lists_on_status             (status)
#  index_lists_on_submitted_by_id    (submitted_by_id)
#  index_lists_on_url                (url)
#  index_lists_on_year_published     (year_published)
#
# Foreign Keys
#
#  fk_rails_...  (submitted_by_id => users.id)
#
module LegacyBooks
  class List < Record
    self.table_name = "lists"
  end
end
