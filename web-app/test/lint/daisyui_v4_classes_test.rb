# frozen_string_literal: true

require "test_helper"

# Guardrail against daisyUI v4 classes creeping back into the app.
#
# This app runs daisyUI 5.7.x. The classes in REMOVED_CLASSES existed in
# daisyUI 4 and were removed in 5 -- they are simply absent from the compiled
# CSS, so using one is a SILENT failure: no build error, no runtime error, no
# visual difference until someone notices a control that looks subtly wrong
# (or, in the case of "select" on a <select multiple>, badly wrong). Because
# ~90 files already contain these classes, "follow the existing pattern in
# this file/a neighbouring file" reliably reproduces the bug -- see CLAUDE.md.
#
# REMOVED_CLASSES: the list. Extend it if a future daisyUI upgrade removes
# more classes app code still relies on.
#
# ALLOWLIST: a literal, generated-once list of files that already contained a
# removed class at the time this guardrail was added. Sweeping all of them to
# daisyUI 5 markup is separate work and deliberately not bundled into whatever
# change added this test. It is a plain array of paths -- not a glob, not a
# directory prefix -- so every grandfathered file is visible here and can be
# deleted as it gets cleaned up. The test enforces both directions:
#   - a NEW file, or a NEW occurrence in a file not on this list, fails the
#     "no removed classes outside the allowlist" assertion below
#   - an allowlisted file that has been fully cleaned up (no more removed
#     classes anywhere in it) fails the "allowlist has no stale entries"
#     assertion -- that failure message tells you which line to delete here
# That second check is what keeps this list shrinking instead of becoming a
# permanent exemption. When you clean up a file, delete its entry.
class DaisyuiV4ClassesTest < ActiveSupport::TestCase
  REMOVED_CLASSES = %w[
    form-control
    label-text
    input-bordered
    select-bordered
    textarea-bordered
  ].freeze

  ALLOWLIST = %w[
    app/components/admin/add_category_modal_component/add_category_modal_component.html.erb
    app/components/admin/add_item_to_list_modal_component/add_item_to_list_modal_component.html.erb
    app/components/admin/add_list_to_configuration_modal_component/add_list_to_configuration_modal_component.html.erb
    app/components/admin/add_penalty_to_configuration_modal_component/add_penalty_to_configuration_modal_component.html.erb
    app/components/admin/attach_penalty_modal_component/attach_penalty_modal_component.html.erb
    app/components/admin/categories/form_component.html.erb
    app/components/admin/categories/show_component.html.erb
    app/components/admin/edit_list_item_form_component/edit_list_item_form_component.html.erb
    app/components/admin/edit_penalty_application_modal_component/edit_penalty_application_modal_component.html.erb
    app/components/admin/games/wizard/parse_step_component.html.erb
    app/components/admin/games/wizard/review_step_component.html.erb
    app/components/admin/games/wizard/source_step_component.html.erb
    app/components/admin/lists/form_component.html.erb
    app/components/admin/lists/index_component.html.erb
    app/components/admin/lists/research_prompt_modal_component.html.erb
    app/components/admin/lists/show_component.html.erb
    app/components/admin/music/albums/wizard/parse_step_component.html.erb
    app/components/admin/music/albums/wizard/review_step_component.html.erb
    app/components/admin/music/songs/wizard/edit_metadata_modal_component.html.erb
    app/components/admin/music/songs/wizard/link_song_modal_component.html.erb
    app/components/admin/music/songs/wizard/parse_step_component.html.erb
    app/components/admin/music/songs/wizard/review_step_component.html.erb
    app/components/admin/music/songs/wizard/search_musicbrainz_modal_component.html.erb
    app/components/admin/music/wizard/base_source_step_component.html.erb
    app/components/admin/music/wizard/link_musicbrainz_url_modal_component.html.erb
    app/components/admin/search_component/search_component.html.erb
    app/components/authentication/widget_component/widget_component.html.erb
    app/components/autocomplete_component.html.erb
    app/components/books/filter_modal_component.html.erb
    app/components/books/filter_option_rows_component.html.erb
    app/components/games/filter_tabs_component.html.erb
    app/components/music/filter_tabs_component.html.erb
    app/components/reviews/modal_component.html.erb
    app/components/user_lists/modal_component/modal_component.html.erb
    app/views/admin/books/authors/_author_relationships_list.html.erb
    app/views/admin/books/authors/_form.html.erb
    app/views/admin/books/authors/show.html.erb
    app/views/admin/books/books/_book_authors_list.html.erb
    app/views/admin/books/books/_book_relationships_list.html.erb
    app/views/admin/books/books/_form.html.erb
    app/views/admin/books/books/show.html.erb
    app/views/admin/books/credits/_add_credit_modal.html.erb
    app/views/admin/books/credits/_credits_list.html.erb
    app/views/admin/books/editions/_form.html.erb
    app/views/admin/books/editions/show.html.erb
    app/views/admin/books/series/_form.html.erb
    app/views/admin/books/series/_series_books_list.html.erb
    app/views/admin/books/series/show.html.erb
    app/views/admin/descriptions/_form_fields.html.erb
    app/views/admin/domain_roles/index.html.erb
    app/views/admin/games/companies/_form.html.erb
    app/views/admin/games/companies/show.html.erb
    app/views/admin/games/games/_companies_list.html.erb
    app/views/admin/games/games/_form.html.erb
    app/views/admin/games/games/index.html.erb
    app/views/admin/games/games/show.html.erb
    app/views/admin/games/list_items_actions/modals/_edit_metadata.html.erb
    app/views/admin/games/list_items_actions/modals/_link_game.html.erb
    app/views/admin/games/list_items_actions/modals/_link_igdb_id.html.erb
    app/views/admin/games/list_items_actions/modals/_search_igdb_games.html.erb
    app/views/admin/games/platforms/_form.html.erb
    app/views/admin/games/platforms/show.html.erb
    app/views/admin/games/series/_form.html.erb
    app/views/admin/games/series/show.html.erb
    app/views/admin/images/_image_card.html.erb
    app/views/admin/music/ai_chats/show.html.erb
    app/views/admin/music/albums/_artists_list.html.erb
    app/views/admin/music/albums/_form.html.erb
    app/views/admin/music/albums/list_items_actions/modals/_edit_metadata.html.erb
    app/views/admin/music/albums/list_items_actions/modals/_link_album.html.erb
    app/views/admin/music/albums/list_items_actions/modals/_search_musicbrainz_artists.html.erb
    app/views/admin/music/albums/list_items_actions/modals/_search_musicbrainz_releases.html.erb
    app/views/admin/music/albums/show.html.erb
    app/views/admin/music/artists/_albums_list.html.erb
    app/views/admin/music/artists/_form.html.erb
    app/views/admin/music/artists/_songs_list.html.erb
    app/views/admin/music/artists/index.html.erb
    app/views/admin/music/artists/ranking_configurations/_form.html.erb
    app/views/admin/music/artists/ranking_configurations/show.html.erb
    app/views/admin/music/artists/show.html.erb
    app/views/admin/music/songs/_artists_list.html.erb
    app/views/admin/music/songs/_form.html.erb
    app/views/admin/music/songs/list_items_actions/modals/_edit_metadata.html.erb
    app/views/admin/music/songs/list_items_actions/modals/_link_song.html.erb
    app/views/admin/music/songs/list_items_actions/modals/_search_musicbrainz_artists.html.erb
    app/views/admin/music/songs/list_items_actions/modals/_search_musicbrainz_recordings.html.erb
    app/views/admin/music/songs/show.html.erb
    app/views/admin/penalties/_form.html.erb
    app/views/admin/penalties/index.html.erb
    app/views/admin/penalties/show.html.erb
    app/views/admin/ranking_configurations/_form.html.erb
    app/views/admin/ranking_configurations/show.html.erb
    app/views/admin/users/_form.html.erb
    app/views/admin/users/show.html.erb
    app/views/books/lists/index.html.erb
    app/views/games/lists/index.html.erb
    app/views/layouts/games/application.html.erb
    app/views/layouts/music/application.html.erb
    app/views/music/lists/_form.html.erb
  ].freeze

  test "no removed daisyUI v4 classes outside the grandfathered allowlist" do
    unexpected = offenders.keys - ALLOWLIST

    assert_empty unexpected,
      "Found daisyUI v4 class(es) removed in v5 (#{REMOVED_CLASSES.join(", ")}) in " \
      "file(s) not on the ALLOWLIST in #{__FILE__}:\n" \
      "#{unexpected.map { |f| "  #{f}: #{offenders[f].join(", ")}" }.join("\n")}\n" \
      "See CLAUDE.md's daisyUI v5 section and docs/external-libraries/daisyui-llms.txt " \
      "for the current markup (fieldset/fieldset-legend, label, bare input/select/checkbox)."
  end

  test "allowlist has no stale entries" do
    stale = ALLOWLIST - offenders.keys

    assert_empty stale,
      "These ALLOWLIST entries in #{__FILE__} no longer contain any removed daisyUI v4 " \
      "class -- the file(s) were cleaned up. Delete the entry so the allowlist keeps " \
      "shrinking:\n#{stale.map { |f| "  #{f}" }.join("\n")}"
  end

  private

  # Path (relative to Rails.root) => array of removed classes found, for
  # every file under app/views/** and app/components/** that uses one.
  #
  # Only scans text inside a `class="..."` (HTML) or `class: "..."` (Ruby
  # hash option) value -- ERB/Ruby comments are stripped first -- and only
  # counts a whole space-separated class token as a hit, never a substring.
  # That second part matters: "file-input-bordered" is a valid, current
  # daisyUI class (the bordered variant of "file-input") that contains
  # "input-bordered" as a substring, and a naive match would wrongly flag it.
  def offenders
    @offenders ||= scan_target_files
  end

  def scan_target_files
    target_files.each_with_object({}) do |relative_path, result|
      classes = removed_classes_in(strip_comments(File.read(Rails.root.join(relative_path))))
      result[relative_path] = classes if classes.any?
    end
  end

  def target_files
    Dir.glob(Rails.root.join("{app/views,app/components}/**/*"))
      .select { |path| File.file?(path) }
      .map { |path| Pathname.new(path).relative_path_from(Rails.root).to_s }
      .sort
  end

  def strip_comments(content)
    content
      .gsub(/<%#.*?%>/m, "") # ERB comments, e.g. <%# ... %>
      .gsub(/^\s*#.*$/, "") # full-line Ruby comments, e.g. in .rb component files
  end

  def removed_classes_in(content)
    found = []
    content.scan(/class\s*[:=]\s*(["'])(.*?)\1/m) do |_quote, value|
      value.split(/\s+/).each do |token|
        found << token if REMOVED_CLASSES.include?(token)
      end
    end
    found.uniq
  end
end
