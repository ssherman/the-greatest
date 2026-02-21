require "test_helper"
require "ostruct"

class Games::WizardParseListJobTest < ActiveSupport::TestCase
  setup do
    @list = lists(:games_list)
    @list.update!(
      raw_html: "<ol><li>Game 1 - Dev 1</li></ol>",
      wizard_state: {"current_step" => 1, "job_status" => "idle"}
    )
  end

  test "job creates list_items from parsed games" do
    parsed_games = [
      OpenStruct.new(rank: 1, title: "Zelda BOTW", developers: ["Nintendo"], release_year: 2017),
      OpenStruct.new(rank: 2, title: "Red Dead 2", developers: ["Rockstar"], release_year: 2018)
    ]

    result = Services::Ai::Result.new(
      success: true,
      data: OpenStruct.new(games: parsed_games)
    )

    Services::Ai::Tasks::Lists::Games::RawParserTask.any_instance.stubs(:call).returns(result)

    Games::WizardParseListJob.new.perform(@list.id)

    @list.reload
    assert_equal 2, @list.list_items.unverified.count

    item1 = @list.list_items.find_by(position: 1)
    assert_equal "Zelda BOTW", item1.metadata["title"]
    assert_equal ["Nintendo"], item1.metadata["developers"]
    assert_equal 2017, item1.metadata["release_year"]
    assert_nil item1.listable_id
    assert_not item1.verified
  end

  test "job updates wizard_state to completed on success" do
    parsed_games = [
      OpenStruct.new(rank: 1, title: "Test", developers: ["Dev"], release_year: nil)
    ]

    result = Services::Ai::Result.new(
      success: true,
      data: OpenStruct.new(games: parsed_games)
    )

    Services::Ai::Tasks::Lists::Games::RawParserTask.any_instance.stubs(:call).returns(result)

    Games::WizardParseListJob.new.perform(@list.id)

    @list.reload
    assert_equal "completed", @list.wizard_manager.step_status("parse")
  end

  test "job sets wizard_state to failed on parse error" do
    result = Services::Ai::Result.new(
      success: false,
      error: "Parse failed"
    )

    Services::Ai::Tasks::Lists::Games::RawParserTask.any_instance.stubs(:call).returns(result)

    Games::WizardParseListJob.new.perform(@list.id)

    @list.reload
    assert_equal "failed", @list.wizard_manager.step_status("parse")
  end

  test "job handles blank raw_html" do
    @list.update!(raw_html: nil)

    Games::WizardParseListJob.new.perform(@list.id)

    @list.reload
    assert_equal "failed", @list.wizard_manager.step_status("parse")
  end

  test "job uses correct listable_type" do
    parsed_games = [
      OpenStruct.new(rank: 1, title: "Test", developers: ["Dev"], release_year: nil)
    ]

    result = Services::Ai::Result.new(
      success: true,
      data: OpenStruct.new(games: parsed_games)
    )

    Services::Ai::Tasks::Lists::Games::RawParserTask.any_instance.stubs(:call).returns(result)

    Games::WizardParseListJob.new.perform(@list.id)

    item = @list.list_items.first
    assert_equal "Games::Game", item.listable_type
  end
end
