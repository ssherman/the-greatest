# frozen_string_literal: true

require "test_helper"

module Music
  module Albums
    class CardComponentTest < ViewComponent::TestCase
      setup do
        @album = music_albums(:dark_side_of_the_moon)
      end

      test "requires either an album or a ranked item" do
        error = assert_raises(ArgumentError) { Music::Albums::CardComponent.new }

        assert_equal "Must provide either album: or ranked_item:", error.message
      end

      test "carries the polymorphic pair the list widget needs" do
        render_inline(Music::Albums::CardComponent.new(album: @album))

        assert_selector "[data-listable-type='Music::Album'][data-listable-id='#{@album.id}']"
      end

      test "links to the album and breaks out of any enclosing turbo frame" do
        render_inline(Music::Albums::CardComponent.new(album: @album))

        assert_selector "a[href='/album/#{@album.slug}'][data-turbo-frame='_top']"
      end

      test "renders the title and the artist credit" do
        render_inline(Music::Albums::CardComponent.new(album: @album))

        assert_selector "h2.card-title", text: @album.title
        assert_selector "p", text: "by #{@album.artists.map(&:name).join(", ")}"
      end

      test "shows a placeholder when the album has no image" do
        render_inline(Music::Albums::CardComponent.new(album: @album))

        assert_selector "figure", text: "No Image"
        assert_no_selector "figure img"
      end

      test "shows no rank badge when rendered from a bare album" do
        render_inline(Music::Albums::CardComponent.new(album: @album))

        assert_no_selector ".badge-primary"
      end

      test "renders the album from a ranked item" do
        # The only album ranked_item fixture is music_albums_unranked_item (item:
        # animals), which has a nil rank -- verified. Adding a ranked fixture is out
        # of scope; the populated rank-badge branch is covered by the games card and
        # song list item tests.
        #
        # The badge still renders here: show_rank? is `ranked_item.present?`, not
        # `ranked_item.rank.present?`, so a rankless ranked_item produces a badge
        # containing a bare "#". Asserted as-is rather than as desired behaviour --
        # changing the component is not part of this work. Anchored so an emptied-out
        # badge (e.g. the rank interpolation deleted) can't slip past; normalize_ws is
        # required because default_normalize_ws is false and the badge's raw text
        # carries newlines/indentation around the "#".
        render_inline(Music::Albums::CardComponent.new(
          ranked_item: ranked_items(:music_albums_unranked_item)
        ))

        assert_selector "h2.card-title", text: music_albums(:animals).title
        assert_selector ".badge-primary", text: /\A#\z/, normalize_ws: true
      end
    end
  end
end
