# == Schema Information
#
# Table name: user_lists
#
#  id                  :bigint           not null, primary key
#  best_ranked         :boolean          default(FALSE)
#  date_read           :date
#  description         :text
#  greatest_books_list :boolean          default(FALSE), not null
#  list_type           :integer
#  name                :string           not null
#  position            :integer
#  public              :boolean          default(FALSE)
#  view_mode           :integer
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  user_id             :bigint           not null
#
# Indexes
#
#  index_user_lists_on_date_read  (date_read)
#  index_user_lists_on_list_type  (list_type)
#  index_user_lists_on_user_id    (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (user_id => users.id)
#
module LegacyBooks
  class UserList < Record
    self.table_name = "user_lists"
  end
end
