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
  module Albums
    class UserList < ::UserList
      has_many :items, through: :user_list_items, source: :listable, source_type: "Music::Album"

      enum :list_type, {favorites: 0, listened: 1, want_to_listen: 2, custom: 3}

      def self.default_list_types
        [:favorites, :listened, :want_to_listen]
      end

      def self.listable_class
        Music::Album
      end

      def self.default_list_name_for(list_type)
        {
          favorites: "Favorite Albums",
          listened: "Albums I've Listened To",
          want_to_listen: "Albums I Want to Listen To"
        }.fetch(list_type.to_sym)
      end
    end
  end
end
