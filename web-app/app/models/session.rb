# == Schema Information
#
# Table name: sessions
#
#  id             :bigint           not null, primary key
#  ip_address     :string
#  last_active_at :datetime         not null
#  user_agent     :string
#  created_at     :datetime         not null
#  updated_at     :datetime         not null
#  user_id        :bigint           not null
#
# Indexes
#
#  index_sessions_on_user_id  (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (user_id => users.id)
#
class Session < ApplicationRecord
  # Idle limit slides with use; MAX_LIFETIME is measured from sign-in and renewal
  # never extends it. RENEW_AFTER throttles last_active_at writes to one a day.
  IDLE_TIMEOUT = 90.days
  MAX_LIFETIME = 1.year
  RENEW_AFTER = 1.day

  belongs_to :user

  scope :expired, ->(now = Time.current) {
    where("last_active_at < ? OR created_at < ?", now - IDLE_TIMEOUT, now - MAX_LIFETIME)
  }
end
