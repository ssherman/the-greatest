# == Schema Information
#
# Table name: correction_fields
#
#  id            :bigint           not null, primary key
#  applied_at    :datetime
#  field_name    :string           not null
#  new_value     :jsonb
#  old_value     :jsonb
#  status        :integer          default(0), not null
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#  correction_id :bigint           not null
#
# Indexes
#
#  index_correction_fields_on_correction_id                 (correction_id)
#  index_correction_fields_on_correction_id_and_field_name  (correction_id,field_name) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (correction_id => corrections.id)
#
class CorrectionField < ApplicationRecord
  belongs_to :correction

  # `applied` rather than `accepted`: accepting a field and writing it are the same
  # act, so a separate accepted state would exist for zero seconds.
  enum :status, {pending: 0, applied: 1, rejected: 2}

  validates :field_name, presence: true, uniqueness: {scope: :correction_id}
end
