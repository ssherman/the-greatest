# == Schema Information
#
# Table name: donations
#
#  id                :bigint           not null, primary key
#  amount            :integer          not null
#  status            :integer          not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  stripe_payment_id :string
#  user_id           :bigint
#
# Indexes
#
#  index_donations_on_user_id  (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (user_id => users.id)
#
module LegacyBooks
  class Donation < Record
    self.table_name = "donations"
  end
end
