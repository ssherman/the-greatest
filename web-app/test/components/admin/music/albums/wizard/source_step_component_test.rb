# frozen_string_literal: true

require "test_helper"

class Admin::Music::Albums::Wizard::SourceStepComponentTest < ViewComponent::TestCase
  setup do
    @list = lists(:music_albums_list)
  end

  test "renders two radio button options" do
    render_inline(Admin::Music::Albums::Wizard::SourceStepComponent.new(list: @list))

    assert_selector "input[type='radio'][name='import_source'][value='custom_html']"
    assert_selector "input[type='radio'][name='import_source'][value='musicbrainz_series']"
  end

  test "displays option titles and descriptions" do
    render_inline(Admin::Music::Albums::Wizard::SourceStepComponent.new(list: @list))

    assert_text "Custom HTML"
    assert_text "MusicBrainz Series"
    assert_text "Paste HTML from any source and parse album data"
    # MusicBrainz Series import is disabled for albums, so shows unavailable message
    assert_text "Not available"
  end

  test "renders continue button" do
    render_inline(Admin::Music::Albums::Wizard::SourceStepComponent.new(list: @list))

    assert_selector "input[type='submit'][value='Continue →']"
  end

  test "form submits to advance_step path" do
    render_inline(Admin::Music::Albums::Wizard::SourceStepComponent.new(list: @list))

    assert_selector "form[action*='advance'][method='post']"
  end

  test "pre-selects custom_html when set in wizard_state" do
    @list.update!(wizard_state: {"import_source" => "custom_html"})
    render_inline(Admin::Music::Albums::Wizard::SourceStepComponent.new(list: @list))

    assert_selector "input[type='radio'][name='import_source'][value='custom_html'][checked]"
  end

  test "pre-selects musicbrainz_series when set in wizard_state (even if disabled)" do
    # The wizard state might have been set before series import was disabled,
    # so we still honor the stored value for display purposes
    @list.update!(wizard_state: {"import_source" => "musicbrainz_series"}, musicbrainz_series_id: "test-mbid-123")
    render_inline(Admin::Music::Albums::Wizard::SourceStepComponent.new(list: @list))

    # Radio is checked (stored state) but disabled (not implemented)
    assert_selector "input[type='radio'][name='import_source'][value='musicbrainz_series'][checked][disabled]"
  end

  # MusicBrainz Series import is intentionally disabled for albums
  # because there is no bulk series importer implemented yet.
  # Unlike songs which have ImportSongsFromMusicbrainzSeries, albums
  # would silently complete with zero imports if series import was allowed.

  test "musicbrainz option is always disabled for albums (not implemented)" do
    # Even with a valid musicbrainz_series_id, series import is disabled
    @list.update!(musicbrainz_series_id: "test-mbid-456")
    render_inline(Admin::Music::Albums::Wizard::SourceStepComponent.new(list: @list))

    assert_selector "input[type='radio'][name='import_source'][value='musicbrainz_series'][disabled]"
    assert_text "Not available - series import is not yet implemented for albums"
  end

  test "musicbrainz_available? returns false for albums" do
    @list.update!(musicbrainz_series_id: "test-mbid")
    component = Admin::Music::Albums::Wizard::SourceStepComponent.new(list: @list)

    assert_equal false, component.musicbrainz_available?
  end

  test "does not auto-select musicbrainz even when musicbrainz_series_id is set" do
    @list.update!(musicbrainz_series_id: "auto-select-mbid", wizard_state: {})
    render_inline(Admin::Music::Albums::Wizard::SourceStepComponent.new(list: @list))

    # Should NOT auto-select musicbrainz since it's disabled for albums
    assert_no_selector "input[type='radio'][name='import_source'][value='musicbrainz_series'][checked]"
  end
end
