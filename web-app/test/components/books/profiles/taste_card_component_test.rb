# frozen_string_literal: true

require "test_helper"

class Books::Profiles::TasteCardComponentTest < ViewComponent::TestCase
  Data = Services::Books::Profiles::Taste::Data

  test "not ready shows progress for the owner and nothing for the public" do
    taste = Data.new(ready: false, qualifying_count: 4, genres: [], subjects: [])

    render_inline Books::Profiles::TasteCardComponent.new(taste: taste, audience: :owner)
    assert_selector "[data-testid='profile-taste-progress'].card-dash progress[value='4'][max='10']"

    refute Books::Profiles::TasteCardComponent.new(taste: taste, audience: :public).render?
    refute Books::Profiles::TasteCardComponent.new(taste: nil, audience: :public).render?
  end

  test "ready renders genre bars and subject links for both audiences" do
    genre = categories(:books_fiction_genre)
    subject = categories(:books_politics_subject)
    taste = Data.new(ready: true, qualifying_count: 12, genres: [[genre, 1.0]], subjects: [subject])

    [:owner, :public].each do |audience|
      render_inline Books::Profiles::TasteCardComponent.new(taste: taste, audience: audience)

      assert_selector "[data-testid='profile-taste'] progress[value='100']"
      assert_selector "[data-testid='profile-taste'] a[href='#{Books::FilterPath.call(categories: [subject])}']"
    end
  end
end
