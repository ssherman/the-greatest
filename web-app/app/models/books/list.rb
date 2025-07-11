# == Schema Information
#
# Table name: lists
#
#  id                  :bigint           not null, primary key
#  category_specific   :boolean
#  description         :text
#  estimated_quality   :integer          default(0), not null
#  formatted_text      :text
#  high_quality_source :boolean
#  location_specific   :boolean
#  name                :string           not null
#  number_of_voters    :integer
#  raw_html            :text
#  source              :string
#  status              :integer          default("unapproved"), not null
#  type                :string           not null
#  url                 :string
#  voter_count_unknown :boolean
#  voter_names_unknown :boolean
#  year_published      :integer
#  yearly_award        :boolean
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  submitted_by_id     :bigint
#
# Indexes
#
#  index_lists_on_submitted_by_id  (submitted_by_id)
#
# Foreign Keys
#
#  fk_rails_...  (submitted_by_id => users.id)
#
module Books
  class List < ::List
    # Books-specific logic can be added here
  end
end
