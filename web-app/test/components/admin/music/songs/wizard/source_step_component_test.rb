# frozen_string_literal: true

require "test_helper"

class Admin::Music::Songs::Wizard::SourceStepComponentTest < ViewComponent::TestCase
  setup do
    @list = lists(:music_songs_list)
  end

  test "renders two radio button options" do
    render_inline(Admin::Music::Songs::Wizard::SourceStepComponent.new(list: @list))

    assert_selector "input[type='radio'][name='import_source'][value='custom_html']"
    assert_selector "input[type='radio'][name='import_source'][value='musicbrainz_series']"
  end

  test "displays option titles and descriptions" do
    @list.update!(musicbrainz_series_id: "test-mbid")
    render_inline(Admin::Music::Songs::Wizard::SourceStepComponent.new(list: @list))

    assert_text "Custom HTML"
    assert_text "MusicBrainz Series"
    assert_text "Paste HTML from any source and parse song data"
    assert_text "Import from MusicBrainz series by MBID"
  end

  test "renders continue button" do
    render_inline(Admin::Music::Songs::Wizard::SourceStepComponent.new(list: @list))

    assert_selector "input[type='submit'][value='Continue →']"
  end

  test "form submits to advance_step path" do
    render_inline(Admin::Music::Songs::Wizard::SourceStepComponent.new(list: @list))

    assert_selector "form[action*='advance'][method='post']"
  end

  test "pre-selects custom_html when set in wizard_state" do
    @list.update!(wizard_state: {"import_source" => "custom_html"})
    render_inline(Admin::Music::Songs::Wizard::SourceStepComponent.new(list: @list))

    assert_selector "input[type='radio'][name='import_source'][value='custom_html'][checked]"
  end

  test "pre-selects musicbrainz_series when set in wizard_state" do
    @list.update!(wizard_state: {"import_source" => "musicbrainz_series"}, musicbrainz_series_id: "test-mbid-123")
    render_inline(Admin::Music::Songs::Wizard::SourceStepComponent.new(list: @list))

    assert_selector "input[type='radio'][name='import_source'][value='musicbrainz_series'][checked]"
  end

  test "disables musicbrainz option when musicbrainz_series_id is not set" do
    @list.update!(musicbrainz_series_id: nil)
    render_inline(Admin::Music::Songs::Wizard::SourceStepComponent.new(list: @list))

    assert_selector "input[type='radio'][name='import_source'][value='musicbrainz_series'][disabled]"
    assert_text "Not available - update the list to add a MusicBrainz series MBID first"
  end

  test "enables musicbrainz option when musicbrainz_series_id is set" do
    @list.update!(musicbrainz_series_id: "test-mbid-456")
    render_inline(Admin::Music::Songs::Wizard::SourceStepComponent.new(list: @list))

    assert_selector "input[type='radio'][name='import_source'][value='musicbrainz_series']:not([disabled])"
    assert_text "MBID: test-mbid-456"
  end

  test "auto-selects musicbrainz when musicbrainz_series_id is set and no prior selection" do
    @list.update!(musicbrainz_series_id: "auto-select-mbid", wizard_state: {})
    render_inline(Admin::Music::Songs::Wizard::SourceStepComponent.new(list: @list))

    assert_selector "input[type='radio'][name='import_source'][value='musicbrainz_series'][checked]"
  end

  test "does not auto-select when wizard_state already has import_source" do
    @list.update!(
      musicbrainz_series_id: "test-mbid",
      wizard_state: {"import_source" => "custom_html"}
    )
    render_inline(Admin::Music::Songs::Wizard::SourceStepComponent.new(list: @list))

    assert_selector "input[type='radio'][name='import_source'][value='custom_html'][checked]"
    assert_selector "input[type='radio'][name='import_source'][value='musicbrainz_series']:not([checked])"
  end

  # Batch mode checkbox tests

  test "renders batch mode checkbox" do
    render_inline(Admin::Music::Songs::Wizard::SourceStepComponent.new(list: @list))

    assert_selector "input[type='checkbox'][name='batch_mode'][value='1']"
    assert_text "Process in batches"
    assert_text "Enable for large plain text lists"
  end

  test "batch mode checkbox is unchecked by default" do
    @list.update!(wizard_state: {})
    render_inline(Admin::Music::Songs::Wizard::SourceStepComponent.new(list: @list))

    assert_selector "input[type='checkbox'][name='batch_mode']:not([checked])"
  end

  test "batch mode checkbox is checked when wizard_state has batch_mode true" do
    @list.update!(wizard_state: {"batch_mode" => true})
    render_inline(Admin::Music::Songs::Wizard::SourceStepComponent.new(list: @list))

    assert_selector "input[type='checkbox'][name='batch_mode'][checked]"
  end

  test "batch mode checkbox is unchecked when wizard_state has batch_mode false" do
    @list.update!(wizard_state: {"batch_mode" => false})
    render_inline(Admin::Music::Songs::Wizard::SourceStepComponent.new(list: @list))

    assert_selector "input[type='checkbox'][name='batch_mode']:not([checked])"
  end
end
