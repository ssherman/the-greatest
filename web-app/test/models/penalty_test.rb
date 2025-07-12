# == Schema Information
#
# Table name: penalties
#
#  id          :bigint           not null, primary key
#  description :text
#  dynamic     :boolean          default(FALSE), not null
#  global      :boolean          default(FALSE), not null
#  media_type  :integer          default("cross_media"), not null
#  name        :string           not null
#  type        :string           not null
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#  user_id     :bigint
#
# Indexes
#
#  index_penalties_on_dynamic     (dynamic)
#  index_penalties_on_global      (global)
#  index_penalties_on_media_type  (media_type)
#  index_penalties_on_type        (type)
#  index_penalties_on_user_id     (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (user_id => users.id)
#
require "test_helper"

class PenaltyTest < ActiveSupport::TestCase
  def setup
    @user = users(:regular_user)
    @ranking_configuration = ranking_configurations(:books_global)
    @list = lists(:books_list)
  end

  # Validations
  test "should be valid with required attributes" do
    penalty = Penalty.new(
      name: "Test Penalty",
      type: "Penalty",
      global: true,
      media_type: :cross_media
    )
    assert penalty.valid?
  end

  test "should require name" do
    penalty = Penalty.new(type: "Penalty", global: true, media_type: :cross_media)
    assert_not penalty.valid?
    assert_includes penalty.errors[:name], "can't be blank"
  end

  test "should require type" do
    penalty = Penalty.new(name: "Test Penalty", global: true, media_type: :cross_media)
    assert_not penalty.valid?
    assert_includes penalty.errors[:type], "can't be blank"
  end

  test "should require user for non-global penalties" do
    penalty = Penalty.new(
      name: "Test Penalty",
      type: "Penalty",
      global: false,
      media_type: :cross_media
    )
    assert_not penalty.valid?
    assert_includes penalty.errors[:user], "must be present for user-specific penalties"
  end

  test "should not require user for global penalties" do
    penalty = Penalty.new(
      name: "Test Penalty",
      type: "Penalty",
      global: true,
      media_type: :cross_media
    )
    assert penalty.valid?
  end

  test "should validate media type consistency for books" do
    penalty = Penalty.new(
      name: "Test Penalty",
      type: "Books::Penalty",
      global: true,
      media_type: :movies
    )
    assert_not penalty.valid?
    assert_includes penalty.errors[:media_type], "must be 'books' for Books::Penalty types"
  end

  test "should validate media type consistency for movies" do
    penalty = Penalty.new(
      name: "Test Penalty",
      type: "Movies::Penalty",
      global: true,
      media_type: :books
    )
    assert_not penalty.valid?
    assert_includes penalty.errors[:media_type], "must be 'movies' for Movies::Penalty types"
  end

  # Associations
  test "should belong to user optionally" do
    penalty = Penalty.new(
      name: "Test Penalty",
      type: "Penalty",
      global: true,
      media_type: :cross_media
    )
    assert penalty.save
    assert_nil penalty.user

    penalty.user = @user
    assert penalty.save
  end

  test "should have many penalty applications" do
    penalty = penalties(:global_penalty)
    assert penalty.penalty_applications.any?
  end

  test "should have many ranking configurations through penalty applications" do
    penalty = penalties(:global_penalty)
    assert penalty.ranking_configurations.any?
  end

  test "should have many list penalties" do
    penalty = penalties(:global_penalty)
    assert penalty.list_penalties.any?
  end

  test "should have many lists through list penalties" do
    penalty = penalties(:global_penalty)
    assert penalty.lists.any?
  end

  # Enums
  test "should have correct media type enum values" do
    assert_equal 0, Penalty.media_types[:cross_media]
    assert_equal 1, Penalty.media_types[:books]
    assert_equal 2, Penalty.media_types[:movies]
    assert_equal 3, Penalty.media_types[:games]
    assert_equal 4, Penalty.media_types[:music]
  end

  # Scopes
  test "should scope global penalties" do
    global_penalties = Penalty.global
    assert global_penalties.all?(&:global?)
  end

  test "should scope user specific penalties" do
    user_penalties = Penalty.user_specific
    assert user_penalties.all?(&:user_specific?)
  end

  test "should scope dynamic penalties" do
    dynamic_penalties = Penalty.dynamic
    assert dynamic_penalties.all?(&:dynamic?)
  end

  test "should scope static penalties" do
    static_penalties = Penalty.static
    assert static_penalties.all?(&:static?)
  end

  test "should scope by media type" do
    books_penalties = Penalty.by_media_type(:books)
    assert books_penalties.all? { |p| p.media_type == "books" }
  end

  test "should scope cross media penalties" do
    cross_media_penalties = Penalty.cross_media
    assert cross_media_penalties.all?(&:cross_media?)
  end

  # Public Methods
  test "should identify global penalties" do
    penalty = penalties(:global_penalty)
    assert penalty.global?
    assert_not penalty.user_specific?
  end

  test "should identify user specific penalties" do
    penalty = penalties(:user_penalty)
    assert penalty.user_specific?
    assert_not penalty.global?
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

  test "should identify cross media penalties" do
    penalty = penalties(:cross_media_penalty)
    assert penalty.cross_media?
    assert_not penalty.media_specific?
  end

  test "should identify media specific penalties" do
    penalty = penalties(:books_penalty)
    assert penalty.media_specific?
    assert_not penalty.cross_media?
  end

  test "should calculate penalty value from penalty applications" do
    penalty = penalties(:global_penalty)
    value = penalty.calculate_penalty_value(@list, @ranking_configuration)
    assert_equal 25, value
  end

  test "should return 0 for penalty value when no application exists" do
    penalty = penalties(:user_penalty)
    value = penalty.calculate_penalty_value(@list, @ranking_configuration)
    assert_equal 0, value
  end

  # STI Subclasses
  test "should create books penalty" do
    penalty = Books::Penalty.create!(
      name: "Books Penalty",
      global: true,
      media_type: :books
    )
    assert_equal "Books::Penalty", penalty.type
    assert_equal "books", penalty.media_type
  end

  test "should create movies penalty" do
    penalty = Movies::Penalty.create!(
      name: "Movies Penalty",
      global: true,
      media_type: :movies
    )
    assert_equal "Movies::Penalty", penalty.type
    assert_equal "movies", penalty.media_type
  end

  test "should create games penalty" do
    penalty = Games::Penalty.create!(
      name: "Games Penalty",
      global: true,
      media_type: :games
    )
    assert_equal "Games::Penalty", penalty.type
    assert_equal "games", penalty.media_type
  end

  test "should create music penalty" do
    penalty = Music::Penalty.create!(
      name: "Music Penalty",
      global: true,
      media_type: :music
    )
    assert_equal "Music::Penalty", penalty.type
    assert_equal "music", penalty.media_type
  end
end
