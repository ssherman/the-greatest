require "test_helper"

class Admin::Lists::ResearchPromptModalComponentTest < ViewComponent::TestCase
  test "renders modal for games list with correct prompt" do
    list = lists(:games_list)
    render_inline(Admin::Lists::ResearchPromptModalComponent.new(list: list))

    assert_selector "dialog#research_prompt_modal_dialog"
    assert_selector "textarea[readonly]"
    assert_selector "button[data-action='clipboard-copy#copy']", text: "Copy to Clipboard"

    prompt_text = page.find("textarea").value
    assert_includes prompt_text, "Video Games List"
    assert_includes prompt_text, "title: #{list.name}"
    assert_includes prompt_text, "source: #{list.source}"
    assert_includes prompt_text, "the games on the list"
    assert_includes prompt_text, "The Greatest Games"
    assert_includes prompt_text, "creator or company"
  end

  test "renders modal for albums list with correct prompt" do
    list = lists(:music_albums_list)
    render_inline(Admin::Lists::ResearchPromptModalComponent.new(list: list))

    prompt_text = page.find("textarea").value
    assert_includes prompt_text, "Albums List"
    assert_includes prompt_text, "title: #{list.name}"
    assert_includes prompt_text, "the albums on the list"
    assert_includes prompt_text, "The Greatest Albums"
    assert_includes prompt_text, "artist or group"
  end

  test "renders modal for songs list with correct prompt" do
    list = lists(:music_songs_list)
    render_inline(Admin::Lists::ResearchPromptModalComponent.new(list: list))

    prompt_text = page.find("textarea").value
    assert_includes prompt_text, "Songs List"
    assert_includes prompt_text, "title: #{list.name}"
    assert_includes prompt_text, "the songs on the list"
    assert_includes prompt_text, "The Greatest Songs"
    assert_includes prompt_text, "artist or group"
  end

  test "does not render for unsupported list types" do
    list = lists(:books_list)
    render_inline(Admin::Lists::ResearchPromptModalComponent.new(list: list))

    assert_no_selector "dialog"
  end

  test "interpolates url as N/A when blank" do
    list = lists(:music_songs_list)
    assert_nil list.url

    component = Admin::Lists::ResearchPromptModalComponent.new(list: list)
    assert_includes component.research_prompt, "url: N/A"
  end

  test "interpolates year_published as Unknown when nil" do
    list = lists(:music_songs_list)
    assert_nil list.year_published

    component = Admin::Lists::ResearchPromptModalComponent.new(list: list)
    assert_includes component.research_prompt, "Year Published: Unknown"
  end

  test "interpolates actual values when present" do
    list = lists(:music_albums_list)
    assert_equal 2020, list.year_published

    component = Admin::Lists::ResearchPromptModalComponent.new(list: list)
    assert_includes component.research_prompt, "Year Published: 2020"
    assert_includes component.research_prompt, "url: #{list.url}" if list.url.present?
  end

  test "prompt includes contributor emphasis section" do
    list = lists(:games_list)
    component = Admin::Lists::ResearchPromptModalComponent.new(list: list)

    assert_includes component.research_prompt, "Number of Contributors (MOST IMPORTANT)"
    assert_includes component.research_prompt, "conservative in your estimate"
    assert_includes component.research_prompt, "Confidence Level"
    assert_includes component.research_prompt, "Source Quality"
  end
end
