require "test_helper"

# == Schema Information
#
# Table name: books_profiles
#
#  id                 :bigint           not null, primary key
#  display_name       :string
#  public             :boolean          default(FALSE), not null
#  show_favorites     :boolean          default(FALSE), not null
#  show_goals         :boolean          default(FALSE), not null
#  show_reading_now   :boolean          default(FALSE), not null
#  show_recently_read :boolean          default(FALSE), not null
#  show_reviews       :boolean          default(FALSE), not null
#  show_stats         :boolean          default(FALSE), not null
#  show_taste         :boolean          default(FALSE), not null
#  show_top_rated     :boolean          default(FALSE), not null
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  user_id            :bigint           not null
#
# Indexes
#
#  index_books_profiles_on_user_id  (user_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (user_id => users.id)
#
class Books::ProfileTest < ActiveSupport::TestCase
  test "a private profile needs no display name" do
    profile = Books::Profile.new(user: users(:regular_user), public: false, display_name: nil)
    assert profile.valid?
  end

  test "a public profile requires a display name of 2 to 40 characters" do
    profile = Books::Profile.new(user: users(:regular_user), public: true)

    [nil, " ", "A", "A" * 41].each do |name|
      profile.display_name = name
      assert_not profile.valid?, "expected #{name.inspect} to be invalid"
      assert profile.errors[:display_name].any?
    end

    ["Al", "A" * 40].each do |name|
      profile.display_name = name
      assert profile.valid?, "expected #{name.inspect} to be valid"
    end
  end

  test "display name is stripped and squished" do
    profile = Books::Profile.new(user: users(:regular_user), public: true, display_name: "  Al   B ")
    profile.valid?
    assert_equal "Al B", profile.display_name
  end

  test "one profile per user" do
    duplicate = Books::Profile.new(user: users(:profile_reader))
    assert_not duplicate.valid?
    assert duplicate.errors[:user_id].any?
  end

  test "show? reads the matching switch and defaults to false" do
    assert Books::Profile::SECTIONS.all? { |section| books_profiles(:public_profile).show?(section) }
    assert Books::Profile::SECTIONS.none? { |section| books_profiles(:private_profile).show?(section) }
    assert_not Books::Profile.new.show?(:stats)
  end

  test "destroying the user destroys the profile" do
    user = users(:profile_reader)
    assert_difference "Books::Profile.count", -1 do
      user.destroy
    end
  end
end
