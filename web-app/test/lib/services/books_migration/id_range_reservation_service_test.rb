require "test_helper"

class Services::BooksMigration::IdRangeReservationServiceTest < ActiveSupport::TestCase
  USERS_CEILING = Services::BooksMigration::RESERVED_CEILINGS.fetch("users")
  USER_LISTS_CEILING = Services::BooksMigration::RESERVED_CEILINGS.fetch("user_lists")
  LISTS_CEILING = Services::BooksMigration::RESERVED_CEILINGS.fetch("lists")

  # Controlled low-id rows seeded into the reserved range. Fixtures use hashed
  # (pseudo-random) ids, so we insert known ids via raw SQL to assert relocation
  # deterministically.
  RESERVED_USER_ID = 5
  RESERVED_LIST_ID = 7
  RESERVED_ITEM_ID = 9
  RESERVED_OTHER_LIST_ID = 11
  RESERVED_LIST_ITEM_ID = 21
  RESERVED_RC_ID = 31
  RESERVED_RANKED_LIST_ID = 41
  RESERVED_PENALTY_ID = 51
  RESERVED_LIST_PENALTY_ID = 61
  RESERVED_AI_CHAT_ID = 71

  setup do
    @conn = ActiveRecord::Base.connection
    seed_reserved_range_rows
  end

  test "relocates reserved-range rows above the ceiling and remaps their FKs" do
    result = Services::BooksMigration::IdRangeReservationService.call
    assert result[:success], "service should succeed: #{result[:error]}"

    # PKs shifted by their own table's ceiling.
    assert_equal RESERVED_USER_ID + USERS_CEILING, relocated_id("users", RESERVED_USER_ID)
    assert_equal RESERVED_LIST_ID + USER_LISTS_CEILING, relocated_id("user_lists", RESERVED_LIST_ID)

    # user_lists.user_id -> users remapped to the relocated parent (users ceiling).
    assert_equal RESERVED_USER_ID + USERS_CEILING,
      @conn.select_value("SELECT user_id FROM user_lists WHERE id = #{RESERVED_LIST_ID + USER_LISTS_CEILING}").to_i

    # lists.submitted_by_id -> users remapped (users ceiling); the lists row itself relocated by LISTS_CEILING.
    assert_equal RESERVED_USER_ID + USERS_CEILING,
      @conn.select_value("SELECT submitted_by_id FROM lists WHERE id = #{RESERVED_OTHER_LIST_ID + LISTS_CEILING}").to_i

    # user_list_items.user_list_id -> user_lists remapped (user_lists ceiling; FK integrity: parent exists).
    assert_equal RESERVED_LIST_ID + USER_LISTS_CEILING,
      @conn.select_value("SELECT user_list_id FROM user_list_items WHERE id = #{RESERVED_ITEM_ID}").to_i
  end

  test "leaves no users or user_lists rows below the ceiling" do
    Services::BooksMigration::IdRangeReservationService.call

    assert_equal 0, @conn.select_value("SELECT COUNT(*) FROM users WHERE id < #{USERS_CEILING}").to_i
    assert_equal 0, @conn.select_value("SELECT COUNT(*) FROM user_lists WHERE id < #{USER_LISTS_CEILING}").to_i
  end

  test "next User and UserList creates land at or above the ceiling" do
    Services::BooksMigration::IdRangeReservationService.call

    user = User.create!(email: "post-migration@example.com", role: :user)
    assert_operator user.id, :>=, USERS_CEILING

    list = Games::UserList.create!(name: "Post Migration", list_type: :custom, user: user)
    assert_operator list.id, :>=, USER_LISTS_CEILING
  end

  test "is idempotent: a second run is a no-op and does not error" do
    first = Services::BooksMigration::IdRangeReservationService.call
    assert first[:success]

    relocated_user = relocated_id("users", RESERVED_USER_ID)
    relocated_list = relocated_id("user_lists", RESERVED_LIST_ID)

    second = Services::BooksMigration::IdRangeReservationService.call
    assert second[:success], "second run should succeed: #{second[:error]}"

    # Rows did not shift a second time.
    assert_equal relocated_user, relocated_id("users", RESERVED_USER_ID)
    assert_equal relocated_list, relocated_id("user_lists", RESERVED_LIST_ID)
  end

  test "a simulated book import at a low reserved id succeeds without collision" do
    Services::BooksMigration::IdRangeReservationService.call

    user = User.create!(email: "book-owner@example.com", role: :user)
    @conn.execute(<<~SQL)
      INSERT INTO user_lists (id, type, list_type, name, user_id, view_mode, public, created_at, updated_at)
      VALUES (42, 'Books::UserList', 5, 'Imported Book List', #{user.id}, 0, false, now(), now())
    SQL

    assert_equal 42, @conn.select_value("SELECT id FROM user_lists WHERE id = 42").to_i
    # Queried via the STI base class on purpose: Books::UserList has no Ruby
    # subclass yet, but the reserved range must still accept a "book" row.
    assert UserList.exists?(42), "book row at reserved id 42 should be findable"
  end

  test "relocates lists and remaps every column that references lists.id" do
    result = Services::BooksMigration::IdRangeReservationService.call
    assert result[:success], "service should succeed: #{result[:error]}"

    relocated = RESERVED_OTHER_LIST_ID + LISTS_CEILING

    assert_equal relocated, relocated_id("lists", RESERVED_OTHER_LIST_ID)
    assert_equal relocated,
      @conn.select_value("SELECT list_id FROM list_items WHERE id = #{RESERVED_LIST_ITEM_ID}").to_i
    assert_equal relocated,
      @conn.select_value("SELECT list_id FROM ranked_lists WHERE id = #{RESERVED_RANKED_LIST_ID}").to_i
    assert_equal relocated,
      @conn.select_value("SELECT list_id FROM list_penalties WHERE id = #{RESERVED_LIST_PENALTY_ID}").to_i
    assert_equal relocated,
      @conn.select_value("SELECT primary_mapped_list_id FROM ranking_configurations WHERE id = #{RESERVED_RC_ID}").to_i
    assert_equal relocated,
      @conn.select_value("SELECT secondary_mapped_list_id FROM ranking_configurations WHERE id = #{RESERVED_RC_ID}").to_i
  end

  test "remaps the polymorphic ai_chats reference to a relocated list" do
    Services::BooksMigration::IdRangeReservationService.call

    assert_equal RESERVED_OTHER_LIST_ID + LISTS_CEILING,
      @conn.select_value("SELECT parent_id FROM ai_chats WHERE id = #{RESERVED_AI_CHAT_ID}").to_i
  end

  test "does not create a foreign key for the FK-less ranked_lists.list_id" do
    refute @conn.foreign_key_exists?("ranked_lists", "lists", column: "list_id"),
      "precondition: ranked_lists.list_id must have no FK"

    Services::BooksMigration::IdRangeReservationService.call

    refute @conn.foreign_key_exists?("ranked_lists", "lists", column: "list_id"),
      "reservation must not add a ranked_lists -> lists FK"
  end

  test "leaves no lists rows below the lists ceiling" do
    Services::BooksMigration::IdRangeReservationService.call

    assert_equal 0, @conn.select_value("SELECT COUNT(*) FROM lists WHERE id < #{LISTS_CEILING}").to_i
  end

  test "next List create lands at or above the lists ceiling" do
    Services::BooksMigration::IdRangeReservationService.call

    list = Books::List.create!(name: "Post-reservation List")
    assert_operator list.id, :>=, LISTS_CEILING
  end

  test "is idempotent for lists: a second run does not shift the list again" do
    assert Services::BooksMigration::IdRangeReservationService.call[:success]
    relocated = relocated_id("lists", RESERVED_OTHER_LIST_ID)

    assert Services::BooksMigration::IdRangeReservationService.call[:success]
    assert_equal relocated, relocated_id("lists", RESERVED_OTHER_LIST_ID)
  end

  test "a simulated book-list import at a low reserved id succeeds without collision" do
    Services::BooksMigration::IdRangeReservationService.call

    @conn.execute(<<~SQL)
      INSERT INTO lists (id, type, name, status, estimated_quality, created_at, updated_at)
      VALUES (42, 'Books::List', 'Imported Book List', 0, 0, now(), now())
    SQL

    assert_equal 42, @conn.select_value("SELECT id FROM lists WHERE id = 42").to_i
    assert List.exists?(42), "book list at reserved id 42 should be findable"
  end

  private

  # `id + ceiling` for a row originally seeded at `original_id`, or nil if absent.
  def relocated_id(table, original_id)
    ceiling = Services::BooksMigration::RESERVED_CEILINGS.fetch(table)
    @conn.select_value("SELECT id FROM #{table} WHERE id = #{original_id + ceiling}")&.to_i
  end

  def seed_reserved_range_rows
    album_id = music_albums(:dark_side_of_the_moon).id

    @conn.execute(<<~SQL)
      INSERT INTO users (id, email, role, email_verified, created_at, updated_at)
      VALUES (#{RESERVED_USER_ID}, 'reserved-user@example.com', 0, false, now(), now())
    SQL
    @conn.execute(<<~SQL)
      INSERT INTO user_lists (id, type, list_type, name, user_id, view_mode, public, created_at, updated_at)
      VALUES (#{RESERVED_LIST_ID}, 'Games::UserList', 5, 'Reserved List', #{RESERVED_USER_ID}, 0, false, now(), now())
    SQL
    @conn.execute(<<~SQL)
      INSERT INTO user_list_items (id, user_list_id, listable_id, listable_type, position, created_at, updated_at)
      VALUES (#{RESERVED_ITEM_ID}, #{RESERVED_LIST_ID}, #{album_id}, 'Music::Album', 1, now(), now())
    SQL
    @conn.execute(<<~SQL)
      INSERT INTO lists (id, type, name, submitted_by_id, status, estimated_quality, created_at, updated_at)
      VALUES (#{RESERVED_OTHER_LIST_ID}, 'Games::List', 'Reserved Source List', #{RESERVED_USER_ID}, 0, 0, now(), now())
    SQL
    @conn.execute(<<~SQL)
      INSERT INTO list_items (id, list_id, verified, created_at, updated_at)
      VALUES (#{RESERVED_LIST_ITEM_ID}, #{RESERVED_OTHER_LIST_ID}, false, now(), now())
    SQL
    @conn.execute(<<~SQL)
      INSERT INTO ranking_configurations
        (id, type, name, primary_mapped_list_id, secondary_mapped_list_id, created_at, updated_at)
      VALUES (#{RESERVED_RC_ID}, 'Games::RankingConfiguration', 'Reserved RC',
              #{RESERVED_OTHER_LIST_ID}, #{RESERVED_OTHER_LIST_ID}, now(), now())
    SQL
    @conn.execute(<<~SQL)
      INSERT INTO ranked_lists (id, list_id, ranking_configuration_id, created_at, updated_at)
      VALUES (#{RESERVED_RANKED_LIST_ID}, #{RESERVED_OTHER_LIST_ID}, #{RESERVED_RC_ID}, now(), now())
    SQL
    @conn.execute(<<~SQL)
      INSERT INTO penalties (id, type, name, created_at, updated_at)
      VALUES (#{RESERVED_PENALTY_ID}, 'Global::Penalty', 'Reserved Penalty', now(), now())
    SQL
    @conn.execute(<<~SQL)
      INSERT INTO list_penalties (id, list_id, penalty_id, created_at, updated_at)
      VALUES (#{RESERVED_LIST_PENALTY_ID}, #{RESERVED_OTHER_LIST_ID}, #{RESERVED_PENALTY_ID}, now(), now())
    SQL
    @conn.execute(<<~SQL)
      INSERT INTO ai_chats (id, model, parent_type, parent_id, created_at, updated_at)
      VALUES (#{RESERVED_AI_CHAT_ID}, 'test-model', 'List', #{RESERVED_OTHER_LIST_ID}, now(), now())
    SQL
  end
end
