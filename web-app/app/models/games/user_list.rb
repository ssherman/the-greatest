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
module Games
  class UserList < ::UserList
    has_many :items, through: :user_list_items, source: :listable, source_type: "Games::Game"

    enum :list_type, {favorites: 0, played: 1, beaten: 2, want_to_play: 3, currently_playing: 4, custom: 5}

    def self.default_list_types
      [:favorites, :played, :beaten, :want_to_play, :currently_playing]
    end

    def self.listable_class
      Games::Game
    end

    def self.default_list_name_for(list_type)
      {
        favorites: "Favorite Games",
        played: "Games I've Played",
        beaten: "Games I've Beaten",
        want_to_play: "Games I Want to Play",
        currently_playing: "Games I'm Currently Playing"
      }.fetch(list_type.to_sym)
    end

    def self.list_type_icons
      {
        favorites: "heart",
        played: "check",
        beaten: "trophy",
        currently_playing: "gamepad-2",
        want_to_play: "bookmark"
      }
    end
  end
end
