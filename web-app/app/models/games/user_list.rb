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
  end
end
