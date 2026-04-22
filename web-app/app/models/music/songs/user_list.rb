# == Schema Information
#
# Table name: user_lists
#
#  id          :bigint           not null, primary key
#  description :text
#  list_type   :integer          not null
#  name        :string           not null
#  position    :integer
#  public      :boolean          default(FALSE), not null
#  type        :string           not null
#  view_mode   :integer          default("default_view"), not null
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#  user_id     :bigint           not null
#
# Indexes
#
#  index_user_lists_on_public            (public) WHERE (public = true)
#  index_user_lists_on_user_id           (user_id)
#  index_user_lists_on_user_id_and_type  (user_id,type)
#
# Foreign Keys
#
#  fk_rails_...  (user_id => users.id)
#
module Music
  module Songs
    class UserList < ::UserList
      has_many :items, through: :user_list_items, source: :listable, source_type: "Music::Song"

      enum :list_type, {favorites: 0, custom: 1}

      def self.default_list_types
        [:favorites]
      end

      def self.listable_class
        Music::Song
      end

      def self.default_list_name_for(list_type)
        {
          favorites: "Favorite Songs"
        }.fetch(list_type.to_sym)
      end
    end
  end
end
