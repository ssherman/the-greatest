# == Schema Information
#
# Table name: reading_goals
#
#  id              :bigint           not null, primary key
#  description     :text
#  end_date        :date             not null
#  name            :string           not null
#  number_of_books :integer          not null
#  percentage_done :decimal(5, 2)    default(0.0)
#  public          :boolean          default(FALSE), not null
#  start_date      :date             not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  user_id         :bigint           not null
#
# Indexes
#
#  index_reading_goals_on_user_id  (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (user_id => users.id)
#
module LegacyBooks
  class ReadingGoal < Record
    self.table_name = "reading_goals"
  end
end
