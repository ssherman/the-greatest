# frozen_string_literal: true

require "test_helper"

class SavedSearchTest < ActiveSupport::TestCase
  test "requires criteria" do
    search = Books::SavedSearch.new(user: users(:regular_user))

    refute search.valid?
    assert_includes search.errors[:criteria], "can't be blank"
  end

  test "requires a user" do
    search = Books::SavedSearch.new(criteria: {"genre_match_mode" => "any"})

    refute search.valid?
  end

  test "display_name falls back to the id when unnamed" do
    search = saved_searches(:books_private)

    assert_equal "Search #{search.id}", search.display_name
  end

  test "display_name prefers the name when present" do
    assert_equal "Great Russian Novels", saved_searches(:books_public).display_name
  end

  test "public_searches returns only public rows" do
    assert_includes SavedSearch.public_searches, saved_searches(:books_public)
    refute_includes SavedSearch.public_searches, saved_searches(:books_private)
  end

  test "owned_by returns only that user's rows" do
    owned = SavedSearch.owned_by(users(:regular_user))

    assert_includes owned, saved_searches(:books_private)
    refute_includes owned, saved_searches(:books_other_user)
  end

  test "visible_to a signed-in user returns their own plus anyone's public" do
    visible = SavedSearch.visible_to(users(:regular_user))

    assert_includes visible, saved_searches(:books_private)
    assert_includes visible, saved_searches(:books_public)
    refute_includes visible, saved_searches(:books_other_user)
  end

  test "visible_to an anonymous viewer returns only public rows" do
    visible = SavedSearch.visible_to(nil)

    assert_includes visible, saved_searches(:books_public)
    refute_includes visible, saved_searches(:books_private)
  end

  test "by_last_executed orders most-recently-run first, nulls last" do
    ids = SavedSearch.by_last_executed.pluck(:id)

    assert_equal saved_searches(:books_public).id, ids.first
  end

  test "the four subclass hooks raise on the root class" do
    [:criteria_class, :query_class, :ranking_configuration_class, :excluded_list_type].each do |hook|
      assert_raises(NotImplementedError) { SavedSearch.public_send(hook) }
    end
  end
end
