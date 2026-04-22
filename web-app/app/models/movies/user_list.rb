module Movies
  class UserList < ::UserList
    has_many :items, through: :user_list_items, source: :listable, source_type: "Movies::Movie"

    enum :list_type, {favorites: 0, watched: 1, want_to_watch: 2, custom: 3}

    def self.default_list_types
      [:favorites, :watched, :want_to_watch]
    end

    def self.listable_class
      Movies::Movie
    end

    def self.default_list_name_for(list_type)
      {
        favorites: "Favorite Movies",
        watched: "Movies I've Watched",
        want_to_watch: "Movies I Want to Watch"
      }.fetch(list_type.to_sym)
    end
  end
end
