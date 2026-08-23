# frozen_string_literal: true

require "test_helper"

module Music
  module Songs
    class ListItemComponentTest < ViewComponent::TestCase
      setup do
        @song = music_songs(:time)
      end

      test "renders a table row linking to the song" do
        render_inline(Music::Songs::ListItemComponent.new(song: @song))

        assert_selector "tr td a[href='/song/#{@song.slug}']", text: @song.title
      end

      test "renders the release year" do
        render_inline(Music::Songs::ListItemComponent.new(song: @song))

        assert_selector "td", text: /\b1973\b/
      end

      test "carries the polymorphic pair the list widget needs" do
        render_inline(Music::Songs::ListItemComponent.new(song: @song))

        assert_selector "td[data-listable-type='Music::Song'][data-listable-id='#{@song.id}']"
      end

      test "renders no rank or index cell by default" do
        render_inline(Music::Songs::ListItemComponent.new(song: @song))

        assert_no_selector ".badge-primary"
        assert_selector "tr td", count: 4
      end

      test "renders the rank badge when given a ranked item" do
        render_inline(Music::Songs::ListItemComponent.new(
          song: @song, ranked_item: ranked_items(:music_songs_ranked_item)
        ))

        # Anchored so "#42" cannot match a corrupted "#420". normalize_ws is required:
        # default_normalize_ws is false and the badge's raw text carries newlines and
        # indentation, which no anchored regex matches (verified).
        assert_selector ".badge-primary", text: /\A#42\z/, normalize_ws: true
        assert_selector "tr td", count: 5
      end

      test "renders a plain index cell when given show_index instead of a rank" do
        render_inline(Music::Songs::ListItemComponent.new(song: @song, show_index: 7))

        assert_no_selector ".badge-primary"
        assert_selector "td", text: /\A7\z/, normalize_ws: true
        assert_selector "tr td", count: 5
      end
    end
  end
end
