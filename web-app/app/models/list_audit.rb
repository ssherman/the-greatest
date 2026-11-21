# == Schema Information
#
# Table name: list_audits
#
#  id               :bigint           not null, primary key
#  after            :jsonb
#  before           :jsonb
#  field_changes    :jsonb
#  finished_at      :datetime
#  lease_expires_at :datetime
#  note             :text
#  sources          :jsonb            not null
#  started_at       :datetime
#  status           :integer          default("in_progress"), not null
#  verdict          :integer
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  list_id          :bigint           not null
#  user_id          :bigint
#
# Indexes
#
#  index_list_audits_on_list_id                 (list_id)
#  index_list_audits_on_status_and_finished_at  (status,finished_at)
#  index_list_audits_on_user_id                 (user_id)
#  index_list_audits_one_open_per_list          (list_id) UNIQUE WHERE (status = 0)
#
# Foreign Keys
#
#  fk_rails_...  (list_id => lists.id)
#  fk_rails_...  (user_id => users.id) ON DELETE => nullify
#
class ListAudit < ApplicationRecord
  LEASE = 3.hours

  belongs_to :list
  belongs_to :user, optional: true

  enum :status, {in_progress: 0, finished: 1, released: 2}
  enum :verdict, {verified: 0, unverifiable: 1}

  scope :open, -> { in_progress.where("lease_expires_at > ?", Time.current) }
  scope :expired, -> { in_progress.where("lease_expires_at <= ?", Time.current) }
  scope :done, -> { finished }

  def expired?
    in_progress? && lease_expires_at.present? && lease_expires_at <= Time.current
  end
end
