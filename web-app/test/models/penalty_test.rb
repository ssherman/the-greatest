# == Schema Information
#
# Table name: penalties
#
#  id           :bigint           not null, primary key
#  description  :text
#  dynamic_type :integer
#  name         :string           not null
#  type         :string           not null
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  user_id      :bigint
#
# Indexes
#
#  index_penalties_on_type     (type)
#  index_penalties_on_user_id  (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (user_id => users.id)
#

require "test_helper"

class PenaltyTest < ActiveSupport::TestCase
  def setup
    @regular_user = users(:regular_user)
  end

  # Associations
  test "should belong to user (optional)" do
    penalty = penalties(:global_penalty)
    assert_nil penalty.user

    penalty = penalties(:user_penalty)
    assert_equal @regular_user, penalty.user
  end

  test "should have penalty applications" do
    penalty = penalties(:global_penalty)
    assert penalty.penalty_applications.any?
  end

  test "should have ranking configurations through penalty applications" do
    penalty = penalties(:global_penalty)
    assert penalty.ranking_configurations.any?
  end

  test "should have list penalties" do
    penalty = penalties(:global_penalty)
    assert penalty.list_penalties.any?
  end

  test "should have lists through list penalties" do
    penalty = penalties(:global_penalty)
    assert penalty.lists.any?
  end

  # Validations
  test "should be valid with valid attributes for Global::Penalty" do
    penalty = Global::Penalty.new(
      name: "Test Global Penalty",
      type: "Global::Penalty"
    )
    assert penalty.valid?
  end

  test "should be valid with valid attributes for media-specific penalty" do
    penalty = Music::Penalty.new(
      name: "Test Music Penalty",
      type: "Music::Penalty"
    )
    assert penalty.valid?
  end

  test "should require name" do
    penalty = Global::Penalty.new(type: "Global::Penalty")
    assert_not penalty.valid?
    assert_includes penalty.errors[:name], "can't be blank"
  end

  test "should require type" do
    penalty = Penalty.new(name: "Test Penalty")
    assert_not penalty.valid?
    assert_includes penalty.errors[:type], "can't be blank"
  end

  test "should allow Global::Penalty without user (system-wide)" do
    penalty = Global::Penalty.new(
      name: "Test Global Penalty",
      type: "Global::Penalty"
    )
    assert penalty.valid?
  end

  test "should allow Global::Penalty with user (user-specific)" do
    penalty = Global::Penalty.new(
      name: "Test User Global Penalty",
      type: "Global::Penalty",
      user: @regular_user
    )
    assert penalty.valid?
  end

  test "should allow media-specific penalty without user (system-wide)" do
    penalty = Music::Penalty.new(
      name: "Test System Music Penalty",
      type: "Music::Penalty"
    )
    assert penalty.valid?
  end

  test "should allow media-specific penalty with user (user-specific)" do
    penalty = Music::Penalty.new(
      name: "Test User Music Penalty",
      type: "Music::Penalty",
      user: @regular_user
    )
    assert penalty.valid?
  end

  # Scopes
  test "should scope dynamic penalties" do
    dynamic_penalties = Penalty.dynamic
    assert dynamic_penalties.all?(&:dynamic?)
  end

  test "should scope static penalties" do
    static_penalties = Penalty.static
    assert static_penalties.all?(&:static?)
  end

  test "should scope by dynamic type" do
    voter_penalties = Penalty.by_dynamic_type(:number_of_voters)
    assert voter_penalties.all? { |p| p.dynamic_type == "number_of_voters" }
  end

  test "User-specific penalties should identify as user-specific" do
    penalty = penalties(:user_penalty)
    assert_instance_of Global::Penalty, penalty
    assert_not penalty.global?
    assert penalty.user_specific?

    penalty = penalties(:user_books_penalty)
    assert_instance_of Books::Penalty, penalty
    assert_not penalty.global?
    assert penalty.user_specific?
  end

  test "should identify dynamic penalties" do
    penalty = penalties(:dynamic_penalty)
    assert penalty.dynamic?
    assert_not penalty.static?
  end

  test "should identify static penalties" do
    penalty = penalties(:static_penalty)
    assert penalty.static?
    assert_not penalty.dynamic?
  end

  # STI Functionality
  test "should create correct STI types" do
    global_penalty = Global::Penalty.create!(name: "Test Global", type: "Global::Penalty")
    assert_equal "Global::Penalty", global_penalty.type
    assert_instance_of Global::Penalty, global_penalty

    music_penalty = Music::Penalty.create!(name: "Test Music", type: "Music::Penalty")
    assert_equal "Music::Penalty", music_penalty.type
    assert_instance_of Music::Penalty, music_penalty

    books_penalty = Books::Penalty.create!(name: "Test Books", type: "Books::Penalty")
    assert_equal "Books::Penalty", books_penalty.type
    assert_instance_of Books::Penalty, books_penalty
  end

  test "should query by STI type" do
    global_penalties = Global::Penalty.all
    assert global_penalties.all? { |p| p.instance_of?(Global::Penalty) }

    music_penalties = Music::Penalty.all
    assert music_penalties.all? { |p| p.instance_of?(Music::Penalty) }
  end
end
