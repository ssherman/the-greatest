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
  validate :field_name_is_declared

  private

  # Defence in depth. Submission only ever builds declared fields, so nothing in
  # the request path can violate this today -- but the admin apply path rewrites
  # new_value, and the whole point of this subsystem is that an agent will write
  # corrections through it later. This is the invariant that lets the applier trust
  # a stored field_name.
  #
  # Resolves through the registry rather than constantizing correctable_type, for
  # the same reason the controllers do.
  def field_name_is_declared
    return if field_name.blank?  # presence validation already reported it

    klass = Services::Corrections::TypeRegistry.resolve(correction&.correctable_type)
    return if klass.nil?         # unknown type is not this validation's job

    return if klass.correctable_fields.key?(field_name)

    errors.add(:field_name, "is not correctable on #{correction.correctable_type}")
  end
end
