# == Schema Information
#
# Table name: changesets
#
#  id              :bigint           not null, primary key
#  applied_at      :datetime
#  change_data     :jsonb
#  changeable_type :string           not null
#  notes           :text
#  rejected_at     :datetime
#  status          :integer          default(0), not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  changeable_id   :bigint           not null
#  user_id         :bigint
#
# Indexes
#
#  index_changesets_on_applied_at   (applied_at)
#  index_changesets_on_changeable   (changeable_type,changeable_id)
#  index_changesets_on_rejected_at  (rejected_at)
#  index_changesets_on_user_id      (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (user_id => users.id)
#
module LegacyBooks
  class Changeset < Record
    self.table_name = "changesets"
  end
end
