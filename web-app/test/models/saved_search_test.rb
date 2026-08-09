# frozen_string_literal: true

require "test_helper"

# == Schema Information
#
# Table name: saved_searches
#
#  id               :bigint           not null, primary key
#  criteria         :jsonb            not null
#  description      :text
#  last_executed_at :datetime
#  name             :string
#  public           :boolean          default(FALSE), not null
#  result_count     :integer
#  type             :string           not null
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  user_id          :bigint           not null
#
# Indexes
#
#  index_saved_searches_on_public            (public) WHERE (public = true)
#  index_saved_searches_on_type_and_user_id  (type,user_id)
#  index_saved_searches_on_user_id           (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (user_id => users.id)
#
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

  test "by_created orders most-recently-created first" do
    older = Books::SavedSearch.create!(user: users(:regular_user), criteria: {"genre_match_mode" => "any"}, created_at: 2.days.ago)
    newer = Books::SavedSearch.create!(user: users(:regular_user), criteria: {"genre_match_mode" => "any"}, created_at: 1.day.ago)

    ids = SavedSearch.where(id: [older.id, newer.id]).by_created.pluck(:id)

    assert_equal [newer.id, older.id], ids
  end

  test "the four subclass hooks raise on the root class" do
    [:criteria_class, :query_class, :ranking_configuration_class, :excluded_list_type].each do |hook|
      assert_raises(NotImplementedError) { SavedSearch.public_send(hook) }
    end
  end

  test "subclass_for returns the STI subclass for a registered domain" do
    assert_equal ::Books::SavedSearch, SavedSearch.subclass_for(:books)
    assert_equal ::Books::SavedSearch, SavedSearch.subclass_for("books")
  end

  test "subclass_for returns nil for a domain with no saved searches" do
    assert_nil SavedSearch.subclass_for(:music)
    assert_nil SavedSearch.subclass_for(:games)
    assert_nil SavedSearch.subclass_for(nil)
  end

  test "filter_labels_class is abstract on the base class" do
    assert_raises(NotImplementedError) { SavedSearch.filter_labels_class }
  end
end
