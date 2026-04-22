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
  module Albums
    class UserListTest < ActiveSupport::TestCase
      test "default_list_types" do
        assert_equal [:favorites, :listened, :want_to_listen], Music::Albums::UserList.default_list_types
      end

      test "listable_class" do
        assert_equal Music::Album, Music::Albums::UserList.listable_class
      end

      test "default_list_name_for returns display name for each default type" do
        assert_equal "Favorite Albums", Music::Albums::UserList.default_list_name_for(:favorites)
        assert_equal "Albums I've Listened To", Music::Albums::UserList.default_list_name_for(:listened)
        assert_equal "Albums I Want to Listen To", Music::Albums::UserList.default_list_name_for(:want_to_listen)
      end

      test "default_list_name_for raises on unknown list_type" do
        assert_raises(KeyError) { Music::Albums::UserList.default_list_name_for(:bogus) }
      end

      test "list_type enum has favorites, listened, want_to_listen, custom" do
        assert_equal %w[favorites listened want_to_listen custom], Music::Albums::UserList.list_types.keys
      end
    end
  end
end
