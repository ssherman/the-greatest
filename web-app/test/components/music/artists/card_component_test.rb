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
        # No artist fixture carries any categories -- verified against
        # test/fixtures/category_items.yml, which has zero Music::Artist rows at
        # all -- so build four here, rolled back after the test by the
        # transactional fixtures (no fixture file touched). This gives the
        # cap-and-overflow branch (card_component.html.erb's limit(3) and the
        # "+N more" span) something real to exercise: a floor (badges must
        # appear at all) and a ceiling (no more than 3 category badges, plus
        # exactly one overflow badge naming the true remainder).
        4.times do |i|
          category = Music::Category.create!(name: "Test Genre #{i}")
          CategoryItem.create!(category: category, item: @artist)
        end

        render_inline(Music::Artists::CardComponent.new(artist: @artist))

        assert_selector ".badge-ghost", count: 4
        assert_selector ".badge-ghost", text: "+1 more"
      end
    end
  end
end
