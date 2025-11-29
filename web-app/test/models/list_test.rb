# == Schema Information
#
# Table name: lists
#
#  id                    :bigint           not null, primary key
#  category_specific     :boolean
#  description           :text
#  estimated_quality     :integer          default(0), not null
#  formatted_text        :text
#  high_quality_source   :boolean
#  items_json            :jsonb
#  location_specific     :boolean
#  name                  :string           not null
#  num_years_covered     :integer
#  number_of_voters      :integer
#  raw_html              :text
#  simplified_html       :text
#  source                :string
#  status                :integer          default("unapproved"), not null
#  type                  :string           not null
#  url                   :string
#  voter_count_estimated :boolean
#  voter_count_unknown   :boolean
#  voter_names_unknown   :boolean
#  wizard_state          :jsonb
#  year_published        :integer
#  yearly_award          :boolean
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#  musicbrainz_series_id :string
#  submitted_by_id       :bigint
#
# Indexes
#
#  index_lists_on_submitted_by_id  (submitted_by_id)
#
# Foreign Keys
#
#  fk_rails_...  (submitted_by_id => users.id)
#
require "test_helper"

class ListTest < ActiveSupport::TestCase
  test "should be valid with valid attributes" do
    assert lists(:basic_list).valid?
  end

  test "should require name" do
    list = lists(:basic_list)
    list.name = nil
    assert_not list.valid?
    assert_includes list.errors[:name], "can't be blank"
  end

  test "should require type" do
    list = lists(:basic_list)
    list.type = nil
    assert_not list.valid?
    assert_includes list.errors[:type], "can't be blank"
  end

  test "should require status" do
    list = lists(:basic_list)
    list.status = nil
    assert_not list.valid?
    assert_includes list.errors[:status], "can't be blank"
  end

  test "should accept valid URL format" do
    list = lists(:basic_list)
    list.url = "https://example.com/list"
    assert list.valid?
  end

  test "should reject invalid URL format" do
    list = lists(:basic_list)
    list.url = "not-a-url"
    assert_not list.valid?
    assert_includes list.errors[:url], "is invalid"
  end

  test "should accept blank URL" do
    list = lists(:basic_list)
    list.url = ""
    assert list.valid?
  end

  test "should have correct enum values" do
    assert_equal 0, List.statuses[:unapproved]
    assert_equal 1, List.statuses[:approved]
    assert_equal 2, List.statuses[:rejected]
  end

  test "approved scope should return approved lists" do
    approved_lists = List.approved
    assert_includes approved_lists, lists(:approved_list)
    assert_includes approved_lists, lists(:high_quality_list)
    assert_not_includes approved_lists, lists(:basic_list)
  end

  test "high_quality scope should return high quality lists" do
    high_quality_lists = List.high_quality
    assert_includes high_quality_lists, lists(:high_quality_list)
    assert_includes high_quality_lists, lists(:approved_list)
    assert_not_includes high_quality_lists, lists(:basic_list)
  end

  test "by_year scope should return lists by year" do
    lists_2023 = List.by_year(2023)
    assert_includes lists_2023, lists(:yearly_award_list)
  end

  test "yearly_awards scope should return yearly award lists" do
    award_lists = List.yearly_awards
    assert_includes award_lists, lists(:yearly_award_list)
    assert_not_includes award_lists, lists(:basic_list)
  end

  test "STI should work with domain-specific classes" do
    books_list = lists(:books_list)
    movies_list = lists(:movies_list)
    music_albums_list = lists(:music_albums_list)
    music_songs_list = lists(:music_songs_list)
    games_list = lists(:games_list)

    assert_equal "Books::List", books_list.type
    assert_equal "Movies::List", movies_list.type
    assert_equal "Music::Albums::List", music_albums_list.type
    assert_equal "Music::Songs::List", music_songs_list.type
    assert_equal "Games::List", games_list.type

    assert books_list.is_a?(Books::List)
    assert movies_list.is_a?(Movies::List)
    assert music_albums_list.is_a?(Music::Albums::List)
    assert music_songs_list.is_a?(Music::Songs::List)
    assert games_list.is_a?(Games::List)
  end

  test "destroying list should destroy associated list_items" do
    list = lists(:basic_list)
    item_count = list.list_items.count
    assert item_count > 0

    list.destroy
    assert_equal 0, ListItem.where(list: list).count
  end

  # Test parse_with_ai! method
  test "parse_with_ai! should call ImportService" do
    list = lists(:basic_list)
    Services::Lists::ImportService.expects(:call).with(list).returns({success: true, data: {}})

    result = list.parse_with_ai!

    assert_equal({success: true, data: {}}, result)
  end

  # Test automatic HTML simplification callback
  test "should automatically simplify HTML when raw_html is present on save" do
    list = lists(:basic_list)
    raw_html = "<div><script>alert('test')</script><p>Content</p></div>"
    simplified = "<div><p>Content</p></div>"

    Services::Html::SimplifierService.expects(:call).with(raw_html).returns(simplified)

    list.raw_html = raw_html
    list.save!

    assert_equal simplified, list.simplified_html
  end

  test "wizard_current_step returns 0 when wizard_state is nil" do
    list = lists(:music_songs_list)
    list.update_column(:wizard_state, nil)
    assert_equal 0, list.wizard_current_step
  end

  test "wizard_current_step returns 0 when wizard_state is empty" do
    list = lists(:music_songs_list)
    list.update!(wizard_state: {})
    assert_equal 0, list.wizard_current_step
  end

  test "wizard_current_step returns stored value" do
    list = lists(:music_songs_list)
    list.update!(wizard_state: {"current_step" => 3})
    assert_equal 3, list.wizard_current_step
  end

  test "wizard_job_status returns idle when wizard_state is nil" do
    list = lists(:music_songs_list)
    list.update_column(:wizard_state, nil)
    assert_equal "idle", list.wizard_job_status
  end

  test "wizard_job_status returns idle by default" do
    list = lists(:music_songs_list)
    list.update!(wizard_state: {})
    assert_equal "idle", list.wizard_job_status
  end

  test "wizard_job_status returns stored value" do
    list = lists(:music_songs_list)
    list.update!(wizard_state: {"job_status" => "running"})
    assert_equal "running", list.wizard_job_status
  end

  test "wizard_job_progress returns 0 when wizard_state is nil" do
    list = lists(:music_songs_list)
    list.update_column(:wizard_state, nil)
    assert_equal 0, list.wizard_job_progress
  end

  test "wizard_job_progress returns 0 by default" do
    list = lists(:music_songs_list)
    list.update!(wizard_state: {})
    assert_equal 0, list.wizard_job_progress
  end

  test "wizard_job_progress returns stored value" do
    list = lists(:music_songs_list)
    list.update!(wizard_state: {"job_progress" => 75})
    assert_equal 75, list.wizard_job_progress
  end

  test "wizard_job_error returns nil when wizard_state is nil" do
    list = lists(:music_songs_list)
    list.update_column(:wizard_state, nil)
    assert_nil list.wizard_job_error
  end

  test "wizard_job_error returns nil by default" do
    list = lists(:music_songs_list)
    list.update!(wizard_state: {})
    assert_nil list.wizard_job_error
  end

  test "wizard_job_error returns stored value" do
    list = lists(:music_songs_list)
    list.update!(wizard_state: {"job_error" => "Something went wrong"})
    assert_equal "Something went wrong", list.wizard_job_error
  end

  test "wizard_job_metadata returns empty hash when wizard_state is nil" do
    list = lists(:music_songs_list)
    list.update_column(:wizard_state, nil)
    assert_equal({}, list.wizard_job_metadata)
  end

  test "wizard_job_metadata returns empty hash by default" do
    list = lists(:music_songs_list)
    list.update!(wizard_state: {})
    assert_equal({}, list.wizard_job_metadata)
  end

  test "wizard_job_metadata returns stored value" do
    list = lists(:music_songs_list)
    list.update!(wizard_state: {"job_metadata" => {"total_items" => 100}})
    assert_equal({"total_items" => 100}, list.wizard_job_metadata)
  end

  test "wizard_in_progress? returns false when wizard_state is nil" do
    list = lists(:music_songs_list)
    list.update_column(:wizard_state, nil)
    assert_not list.wizard_in_progress?
  end

  test "wizard_in_progress? returns false when not started" do
    list = lists(:music_songs_list)
    list.update!(wizard_state: {})
    assert_not list.wizard_in_progress?
  end

  test "wizard_in_progress? returns true when started but not completed" do
    list = lists(:music_songs_list)
    list.update!(wizard_state: {"started_at" => Time.current.iso8601})
    assert list.wizard_in_progress?
  end

  test "wizard_in_progress? returns false when completed" do
    list = lists(:music_songs_list)
    list.update!(wizard_state: {
      "started_at" => 1.hour.ago.iso8601,
      "completed_at" => Time.current.iso8601
    })
    assert_not list.wizard_in_progress?
  end

  test "update_wizard_job_status works when wizard_state is nil" do
    list = lists(:music_songs_list)
    list.update_column(:wizard_state, nil)

    list.update_wizard_job_status(
      status: "running",
      progress: 50,
      metadata: {total_items: 100}
    )

    assert_equal "running", list.wizard_job_status
    assert_equal 50, list.wizard_job_progress
    assert_equal({"total_items" => 100}, list.wizard_job_metadata)
  end

  test "update_wizard_job_status merges new state" do
    list = lists(:music_songs_list)
    list.reset_wizard!

    list.update_wizard_job_status(
      status: "running",
      progress: 50,
      metadata: {total_items: 100}
    )

    assert_equal "running", list.wizard_job_status
    assert_equal 50, list.wizard_job_progress
    assert_equal({"total_items" => 100}, list.wizard_job_metadata)
  end

  test "update_wizard_job_status preserves existing metadata" do
    list = lists(:music_songs_list)
    list.update!(wizard_state: {"job_metadata" => {"total_items" => 100}})

    list.update_wizard_job_status(
      status: "running",
      metadata: {processed_items: 50}
    )

    expected = {"total_items" => 100, "processed_items" => 50}
    assert_equal expected, list.wizard_job_metadata
  end

  test "update_wizard_job_status preserves progress if not provided" do
    list = lists(:music_songs_list)
    list.update!(wizard_state: {"job_progress" => 30})

    list.update_wizard_job_status(status: "running")

    assert_equal 30, list.wizard_job_progress
  end

  test "reset_wizard! sets all initial values" do
    list = lists(:music_songs_list)
    list.reset_wizard!

    assert_equal 0, list.wizard_current_step
    assert_equal "idle", list.wizard_job_status
    assert_equal 0, list.wizard_job_progress
    assert_nil list.wizard_job_error
    assert_equal({}, list.wizard_job_metadata)
    assert_equal({}, list.wizard_state["step_data"])
    assert list.wizard_state["started_at"].present?
    assert_nil list.wizard_state["completed_at"]
  end
end
