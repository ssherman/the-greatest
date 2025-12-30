# frozen_string_literal: true

require "test_helper"

class Admin::Music::Albums::Wizard::CompleteStepComponentTest < ViewComponent::TestCase
  setup do
    @list = lists(:music_albums_list)
    @list.list_items.destroy_all

    @album1 = music_albums(:dark_side_of_the_moon)
    @album2 = music_albums(:wish_you_were_here)

    @list.list_items.create!(
      listable: @album1,
      listable_type: "Music::Album",
      verified: true,
      position: 1,
      metadata: {"title" => "Album 1"}
    )

    @list.list_items.create!(
      listable: @album2,
      listable_type: "Music::Album",
      verified: true,
      position: 2,
      metadata: {"title" => "Album 2"}
    )

    @list.list_items.create!(
      listable_type: "Music::Album",
      listable_id: nil,
      verified: false,
      position: 3,
      metadata: {"title" => "Unlinked Album"}
    )

    @list.update!(wizard_state: {
      "current_step" => 6,
      "import_source" => "custom_html",
      "completed_at" => Time.current.iso8601,
      "steps" => {
        "import" => {
          "status" => "completed",
          "progress" => 100,
          "metadata" => {
            "imported_count" => 2,
            "failed_count" => 1
          }
        }
      }
    })
  end

  test "renders success message" do
    render_inline(Admin::Music::Albums::Wizard::CompleteStepComponent.new(list: @list))

    assert_text "Import Complete!"
  end

  test "displays total items count" do
    render_inline(Admin::Music::Albums::Wizard::CompleteStepComponent.new(list: @list))

    assert_selector ".stat-title", text: "Total Albums"
    assert_selector ".stat-value", text: "3"
  end

  test "displays linked items count" do
    render_inline(Admin::Music::Albums::Wizard::CompleteStepComponent.new(list: @list))

    assert_selector ".stat-title", text: "Linked"
    assert_selector ".stat-value", text: "2"
  end

  test "displays verified items count" do
    render_inline(Admin::Music::Albums::Wizard::CompleteStepComponent.new(list: @list))

    assert_selector ".stat-title", text: "Verified"
    assert_selector ".stat-value", text: "2"
  end

  test "displays unlinked items count when present" do
    render_inline(Admin::Music::Albums::Wizard::CompleteStepComponent.new(list: @list))

    assert_selector ".stat-title", text: "Unlinked"
    assert_selector ".stat-value", text: "1"
  end

  test "does not display unlinked section when all items linked" do
    # Link unlinked item to a different album to avoid duplicate validation
    unlinked_item = @list.list_items.find_by(listable_id: nil)
    unlinked_item.update!(listable_id: music_albums(:animals).id)

    render_inline(Admin::Music::Albums::Wizard::CompleteStepComponent.new(list: @list))

    assert_no_selector ".stat-title", text: "Unlinked"
  end

  test "displays import summary when available" do
    render_inline(Admin::Music::Albums::Wizard::CompleteStepComponent.new(list: @list))

    assert_text "2 albums imported"
    assert_text "1 failed"
  end

  test "renders View List button" do
    render_inline(Admin::Music::Albums::Wizard::CompleteStepComponent.new(list: @list))

    assert_selector "a", text: "View List"
  end

  test "renders Back to Lists button" do
    render_inline(Admin::Music::Albums::Wizard::CompleteStepComponent.new(list: @list))

    assert_selector "a", text: "Back to Lists"
  end

  test "renders success icon" do
    render_inline(Admin::Music::Albums::Wizard::CompleteStepComponent.new(list: @list))

    assert_selector ".text-success svg"
  end
end
