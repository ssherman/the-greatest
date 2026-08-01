# == Schema Information
#
# Table name: list_con_lists
#
#  id             :bigint           not null, primary key
#  created_at     :datetime         not null
#  updated_at     :datetime         not null
#  list_con_id    :bigint           not null
#  ranked_list_id :bigint           not null
#
# Indexes
#
#  index_list_con_lists_on_list_con_id_and_ranked_list_id  (list_con_id,ranked_list_id) UNIQUE
#  index_list_con_lists_on_ranked_list_id                  (ranked_list_id)
#
# Foreign Keys
#
#  fk_rails_...  (list_con_id => list_cons.id)
#  fk_rails_...  (ranked_list_id => ranked_lists.id)
#
module LegacyBooks
  class ListConList < Record
    self.table_name = "list_con_lists"
  end
end
