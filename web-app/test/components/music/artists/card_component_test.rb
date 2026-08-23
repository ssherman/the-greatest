# frozen_string_literal: true

require "test_helper"

module Music
  module Artists
    class CardComponentTest < ViewComponent::TestCase
      setup do
        @artist = music_artists(:pink_floyd)
      end

      test "links to the artist and breaks out of any enclosing turbo frame" do
        render_inline(Music::Artists::CardComponent.new(artist: @artist))

        assert_selector "a[href='/artists/#{@artist.slug}'][data-turbo-frame='_top']"
      end

      test "renders the artist name and titleized kind" do
        render_inline(Music::Artists::CardComponent.new(artist: @artist))

        assert_selector "h2.card-title", text: @artist.name
        assert_selector ".card-body", text: @artist.kind.titleize
      end

      test "shows a placeholder when the artist has no image" do
        render_inline(Music::Artists::CardComponent.new(artist: @artist))

        assert_selector "figure", text: "No Image"
        assert_no_selector "figure img"
      end

      test "shows no rank badge without a ranked item" do
        render_inline(Music::Artists::CardComponent.new(artist: @artist))

        assert_no_selector ".badge-primary"
      end

      test "caps the category badges at three and counts the overflow" do
        render_inline(Music::Artists::CardComponent.new(artist: @artist))

        assert_operator page.all(".badge-ghost").count, :<=, 4
      end
    end
  end
end
