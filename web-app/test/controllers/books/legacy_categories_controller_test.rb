require "test_helper"

module Books
  class LegacyCategoriesControllerTest < ActionDispatch::IntegrationTest
    setup do
      host! Rails.application.config.domains[:books]
    end

    test "redirects a category slug to its filter page permanently" do
      get "/genres/fiction"

      assert_response :moved_permanently
      assert_redirected_to "/the-greatest/fiction/books"
    end

    test "redirects a location category, not only a genre" do
      get "/genres/france"

      assert_response :moved_permanently
      assert_redirected_to "/the-greatest/france/books"
    end

    test "redirects a subject category" do
      get "/genres/politics"

      assert_response :moved_permanently
      assert_redirected_to "/the-greatest/politics/books"
    end

    # Legacy ids were NOT preserved -- CategoryMigrator is a fresh-id migrator --
    # so a numeric legacy id can only resolve through LegacyIdMap.
    test "redirects a numeric legacy id through the id map" do
      category = categories(:books_classics_genre)
      LegacyIdMap.record(model: "Books::Category", legacy_id: 987654, new_id: category.id)

      get "/genres/987654"

      assert_response :moved_permanently
      assert_redirected_to "/the-greatest/classics/books"
    end

    # 206 books categories have a purely numeric slug. A slug must beat a
    # coincidentally equal legacy id, matching legacy's friendly.find ordering.
    # update_column, not update!: Category#should_generate_new_friendly_id? is
    # `slug.blank? || name_changed?`, so an explicit slug: on create is silently
    # overwritten from the name.
    test "a numeric slug wins over the same number as a legacy id" do
      collider = Books::Category.create!(name: "Collider Genre", category_type: :genre)
      collider.update_column(:slug, "555555")
      LegacyIdMap.record(
        model: "Books::Category", legacy_id: 555555, new_id: categories(:books_novels_genre).id
      )

      get "/genres/555555"

      assert_response :moved_permanently
      assert_redirected_to "/the-greatest/555555/books"
    end

    test "404s a soft-deleted category the way legacy does" do
      assert categories(:books_deleted_genre).deleted

      get "/genres/retired-genre"

      assert_response :not_found
    end

    test "404s a numeric legacy id that maps to a soft-deleted category" do
      LegacyIdMap.record(
        model: "Books::Category", legacy_id: 424242, new_id: categories(:books_deleted_genre).id
      )

      get "/genres/424242"

      assert_response :not_found
    end

    test "404s an unknown slug" do
      get "/genres/no-such-category-anywhere"

      assert_response :not_found
    end

    test "404s an unmapped numeric id" do
      get "/genres/99999999"

      assert_response :not_found
    end

    # These three prove route ordering end to end. They live here rather than in
    # test/routing/books_browse_routing_test.rb because assert_recognizes
    # resolves the controller CLASS, so they cannot run until this controller
    # exists -- and asserting the redirect target proves more than recognition.

    # Production has real, active categories named "Page" (location) and
    # "Search" (subject); dev confirms both. They are created here rather than
    # added to test/fixtures/categories.yml because only these two tests need
    # them. FriendlyId derives the slug from the name, so no explicit slug: is
    # passed -- Category#should_generate_new_friendly_id? would overwrite it.
    test "the bare page path resolves the category named Page" do
      category = Books::Category.create!(name: "Page", category_type: :location)
      assert_equal "page", category.slug

      get "/genres/page"

      assert_response :moved_permanently
      assert_redirected_to "/the-greatest/page/books"
    end

    # Legacy shadowed its real "Search" category with a JSON typeahead endpoint,
    # purely because collection routes are declared before the member route.
    # Nothing points a JSON client at this app, so it resolves as the category
    # it is.
    test "the legacy search path resolves the category named Search" do
      category = Books::Category.create!(name: "Search", category_type: :subject)
      assert_equal "search", category.slug

      get "/genres/search"

      assert_response :moved_permanently
      assert_redirected_to "/the-greatest/search/books"
    end

    # Books::Category is STI-scoped. A music category must never resolve here.
    test "404s a category belonging to another domain" do
      music = categories(:music_rock_genre)
      assert_equal "Music::Category", music.type

      get "/genres/#{music.slug}"

      assert_response :not_found
    end
  end
end
