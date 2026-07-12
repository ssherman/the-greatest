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
module Books
  class UserList < ::UserList
    has_many :items, through: :user_list_items, source: :listable, source_type: "Books::Book"

    enum :list_type, {favorites: 0, read: 1, reading: 2, want_to_read: 3, custom: 4}

    def self.default_list_types
      [:favorites, :read, :reading, :want_to_read]
    end

    def self.listable_class
      Books::Book
    end

    def self.default_list_name_for(list_type)
      {
        favorites: "My Favorite Books",
        read: "Books I've Read",
        reading: "Books I'm Reading",
        want_to_read: "Books I Want to Read"
      }.fetch(list_type.to_sym)
    end

    def self.list_type_icons
      {favorites: "heart", read: "check", reading: "book-open", want_to_read: "bookmark"}
    end

    def self.completed_on_list_types
      [:read]
    end

    def self.ranking_configuration_class
      Books::RankingConfiguration
    end

    def self.listable_display_includes
      [:authors, :categories, :primary_image]
    end
  end
end
