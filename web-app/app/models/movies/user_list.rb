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
