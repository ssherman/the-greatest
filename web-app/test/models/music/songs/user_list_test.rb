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
require "test_helper"

module Music
  module Songs
    class UserListTest < ActiveSupport::TestCase
      test "default_list_types" do
        assert_equal [:favorites], Music::Songs::UserList.default_list_types
      end

      test "listable_class" do
        assert_equal Music::Song, Music::Songs::UserList.listable_class
      end

      test "default_list_name_for" do
        assert_equal "Favorite Songs", Music::Songs::UserList.default_list_name_for(:favorites)
      end

      test "list_type enum has favorites, custom" do
        assert_equal %w[favorites custom], Music::Songs::UserList.list_types.keys
      end

      test "list_type_icons" do
        assert_equal({favorites: "heart"}, Music::Songs::UserList.list_type_icons)
      end
    end
  end
end
