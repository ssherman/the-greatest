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
