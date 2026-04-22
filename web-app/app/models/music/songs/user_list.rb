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
