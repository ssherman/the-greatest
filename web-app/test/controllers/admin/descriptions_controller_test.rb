require "test_helper"

class Admin::DescriptionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @album = music_albums(:dark_side_of_the_moon)
    @description = descriptions(:dark_side_ai)
    @admin_user = users(:admin_user)
    @regular_user = users(:regular_user)
    host! Rails.application.config.domains[:music]
  end

  test "redirects unauthenticated users from index" do
    get admin_album_descriptions_path(@album)
    assert_redirected_to music_root_path
  end

  test "redirects regular users from index" do
    sign_in_as(@regular_user, stub_auth: true)
    get admin_album_descriptions_path(@album)
    assert_redirected_to music_root_path
  end

  test "admins can view the index" do
    sign_in_as(@admin_user, stub_auth: true)
    get admin_album_descriptions_path(@album)
    assert_response :success
  end

  test "creates a description at rank normal" do
    sign_in_as(@admin_user, stub_auth: true)
    album = music_albums(:animals)

    assert_difference "Description.count", 1 do
      post admin_album_descriptions_path(album), params: {
        description: {content: "A hand-written summary.", source: "manual"}
      }
    end

    row = Description.last
    assert_equal "manual", row.source
    assert_equal "summary", row.kind
    assert_equal "en", row.locale
    assert_equal "normal", row.rank
    assert_equal album, row.describable
  end

  test "create accepts source_url and license" do
    sign_in_as(@admin_user, stub_auth: true)
    album = music_albums(:animals)

    post admin_album_descriptions_path(album), params: {
      description: {
        content: "From Wikipedia.", source: "wikipedia",
        source_url: "https://en.wikipedia.org/wiki/Animals", license: "cc_by_sa_4"
      }
    }

    row = Description.last
    assert_equal "https://en.wikipedia.org/wiki/Animals", row.source_url
    assert_equal "cc_by_sa_4", row.license
  end

  test "create requires source_name for :other" do
    sign_in_as(@admin_user, stub_auth: true)
    album = music_albums(:animals)

    assert_no_difference "Description.count" do
      post admin_album_descriptions_path(album), params: {
        description: {content: "Unattributed.", source: "other"}
      }
    end
  end

  test "create rejects a duplicate natural key without raising" do
    sign_in_as(@admin_user, stub_auth: true)

    assert_no_difference "Description.count" do
      post admin_album_descriptions_path(@album), params: {
        description: {content: "A second ai_generated row.", source: "ai_generated"}
      }
    end
  end

  test "create ignores a rank parameter" do
    sign_in_as(@admin_user, stub_auth: true)
    album = music_albums(:animals)

    post admin_album_descriptions_path(album), params: {
      description: {content: "Sneaky.", source: "manual", rank: "preferred"}
    }

    assert_equal "normal", Description.last.rank
  end

  test "updates content" do
    sign_in_as(@admin_user, stub_auth: true)

    patch admin_description_path(@description), params: {
      description: {content: "Edited by an admin."}
    }

    assert_equal "Edited by an admin.", @description.reload.content
  end

  test "update ignores a rank parameter" do
    sign_in_as(@admin_user, stub_auth: true)
    row = music_albums(:animals).descriptions.create!(
      kind: :summary, locale: "en", source: :manual, content: "Normal rank."
    )

    patch admin_description_path(row), params: {description: {rank: "preferred"}}

    assert_equal "normal", row.reload.rank
  end

  test "destroys a description" do
    sign_in_as(@admin_user, stub_auth: true)

    assert_difference "Description.count", -1 do
      delete admin_description_path(@description)
    end
  end

  test "set_preferred demotes the incumbent and promotes the target" do
    sign_in_as(@admin_user, stub_auth: true)
    album = music_albums(:dark_side_of_the_moon)
    incumbent = descriptions(:dark_side_ai)
    challenger = album.descriptions.create!(
      kind: :summary, locale: "en", source: :wikipedia, content: "A wikipedia row."
    )

    post set_preferred_admin_description_path(challenger)

    assert_equal "preferred", challenger.reload.rank
    assert_equal "normal", incumbent.reload.rank
    assert_equal 1, album.descriptions.where(rank: :preferred).count
  end

  test "set_preferred is idempotent on an already-preferred row" do
    sign_in_as(@admin_user, stub_auth: true)

    post set_preferred_admin_description_path(@description)

    assert_equal "preferred", @description.reload.rank
    assert_equal 1, @album.descriptions.where(rank: :preferred).count
  end

  test "set_preferred only demotes within the same kind and locale" do
    sign_in_as(@admin_user, stub_auth: true)
    books_books(:war_and_peace)
    other_kind = descriptions(:war_and_peace_long)
    other_kind.update!(rank: :preferred)
    target = descriptions(:war_and_peace_ai)
    host! Rails.application.config.domains[:books]
    sign_in_as(@admin_user, stub_auth: true)

    post set_preferred_admin_description_path(target)

    assert_equal "preferred", target.reload.rank
    assert_equal "preferred", other_kind.reload.rank
  end

  test "regular users cannot create, update, destroy or set_preferred" do
    sign_in_as(@regular_user, stub_auth: true)

    assert_no_difference "Description.count" do
      post admin_album_descriptions_path(@album), params: {
        description: {content: "Nope.", source: "manual"}
      }
    end
    assert_redirected_to music_root_path

    patch admin_description_path(@description), params: {description: {content: "Nope."}}
    assert_redirected_to music_root_path

    post set_preferred_admin_description_path(@description)
    assert_redirected_to music_root_path

    assert_no_difference "Description.count" do
      delete admin_description_path(@description)
    end
  end
end
