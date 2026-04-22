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

module Movies
  class UserListTest < ActiveSupport::TestCase
    test "default_list_types" do
      assert_equal [:favorites, :watched, :want_to_watch], Movies::UserList.default_list_types
    end

    test "listable_class" do
      assert_equal Movies::Movie, Movies::UserList.listable_class
    end

    test "default_list_name_for" do
      assert_equal "Favorite Movies", Movies::UserList.default_list_name_for(:favorites)
      assert_equal "Movies I've Watched", Movies::UserList.default_list_name_for(:watched)
      assert_equal "Movies I Want to Watch", Movies::UserList.default_list_name_for(:want_to_watch)
    end

    test "list_type enum keys" do
      assert_equal %w[favorites watched want_to_watch custom], Movies::UserList.list_types.keys
    end
  end
end
