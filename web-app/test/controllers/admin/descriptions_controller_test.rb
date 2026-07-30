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
      }, as: :turbo_stream
    end
    assert_response :unprocessable_entity
  end

  test "create with a blank source_name succeeds and normalizes to nil" do
    sign_in_as(@admin_user, stub_auth: true)
    album = music_albums(:animals)

    assert_difference "Description.count", 1 do
      post admin_album_descriptions_path(album), params: {
        description: {content: "Blank source name.", source: "manual", source_name: ""}
      }
    end

    assert_nil Description.last.source_name
  end

  test "create still requires source_name for :other when a blank string is submitted" do
    sign_in_as(@admin_user, stub_auth: true)
    album = music_albums(:animals)

    assert_no_difference "Description.count" do
      post admin_album_descriptions_path(album), params: {
        description: {content: "Unattributed.", source: "other", source_name: ""}
      }, as: :turbo_stream
    end
    assert_response :unprocessable_entity
  end

  test "create rejects a duplicate natural key without raising" do
    sign_in_as(@admin_user, stub_auth: true)

    assert_no_difference "Description.count" do
      post admin_album_descriptions_path(@album), params: {
        description: {content: "A second ai_generated row.", source: "ai_generated"}
      }, as: :turbo_stream
    end
    assert_response :unprocessable_entity
  end

  test "create ignores a rank parameter" do
    sign_in_as(@admin_user, stub_auth: true)
    album = music_albums(:animals)

    post admin_album_descriptions_path(album), params: {
      description: {content: "Sneaky.", source: "manual", rank: "preferred"}
    }

    assert_equal "normal", Description.last.rank
  end

  test "create ignores kind and locale parameters" do
    sign_in_as(@admin_user, stub_auth: true)
    album = music_albums(:animals)

    post admin_album_descriptions_path(album), params: {
      description: {content: "Sneaky kind and locale.", source: "manual", kind: "long", locale: "fr"}
    }

    row = Description.last
    assert_equal "summary", row.kind
    assert_equal "en", row.locale
  end

  test "updates content" do
    sign_in_as(@admin_user, stub_auth: true)

    patch admin_description_path(@description), params: {
      description: {content: "Edited by an admin."}
    }

    assert_equal "Edited by an admin.", @description.reload.content
  end

  test "update with a blank source_name on a named-source row succeeds" do
    sign_in_as(@admin_user, stub_auth: true)

    patch admin_description_path(@description), params: {
      description: {content: "Edited by an admin.", source_name: ""}
    }

    @description.reload
    assert_equal "Edited by an admin.", @description.content
    assert_nil @description.source_name
  end

  test "update ignores a rank parameter" do
    sign_in_as(@admin_user, stub_auth: true)
    row = music_albums(:animals).descriptions.create!(
      kind: :summary, locale: "en", source: :manual, content: "Normal rank."
    )

    patch admin_description_path(row), params: {description: {rank: "preferred"}}

    assert_equal "normal", row.reload.rank
  end

  test "update ignores kind and locale parameters" do
    sign_in_as(@admin_user, stub_auth: true)

    patch admin_description_path(@description), params: {
      description: {content: "Edited.", kind: "long", locale: "fr"}
    }

    @description.reload
    assert_equal "summary", @description.kind
    assert_equal "en", @description.locale
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
    other_kind = descriptions(:war_and_peace_long)
    other_kind.update!(rank: :preferred)
    other_locale = descriptions(:war_and_peace_fr)
    other_locale.update!(rank: :preferred)
    target = descriptions(:war_and_peace_ai)
    host! Rails.application.config.domains[:books]
    sign_in_as(@admin_user, stub_auth: true)

    post set_preferred_admin_description_path(target)

    assert_equal "preferred", target.reload.rank
    assert_equal "preferred", other_kind.reload.rank
    assert_equal "preferred", other_locale.reload.rank
  end

  test "set_preferred only demotes within the same describable" do
    sign_in_as(@admin_user, stub_auth: true)
    sibling_preferred = descriptions(:crime_preferred)
    target = descriptions(:war_and_peace_ai)
    host! Rails.application.config.domains[:books]
    sign_in_as(@admin_user, stub_auth: true)

    post set_preferred_admin_description_path(target)

    assert_equal "preferred", target.reload.rank
    assert_equal "preferred", sibling_preferred.reload.rank
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

  # Domain-scoped editor access (shared-controller domain-auth fix, mirrors
  # Admin::ImagesControllerTest's "Domain-scoped editor access" section)

  test "should deny a music domain editor on update of a books description" do
    book_description = descriptions(:war_and_peace_ai)
    sign_in_as(users(:contractor_user), stub_auth: true) # music editor, no books role

    patch admin_description_path(book_description), params: {
      description: {content: "Hacked."}
    }

    assert_redirected_to music_root_path
    assert_not_equal "Hacked.", book_description.reload.content
  end

  test "should deny a music domain editor on destroy of a books description" do
    book_description = descriptions(:war_and_peace_ai)
    sign_in_as(users(:contractor_user), stub_auth: true)

    assert_no_difference "Description.count" do
      delete admin_description_path(book_description)
    end
    assert_redirected_to music_root_path
  end

  test "should deny a music domain editor on set_preferred of a books description" do
    book_description = descriptions(:war_and_peace_ai)
    sign_in_as(users(:contractor_user), stub_auth: true)

    post set_preferred_admin_description_path(book_description)

    assert_redirected_to music_root_path
    assert_not_equal "preferred", book_description.reload.rank
  end

  test "should allow a music domain viewer to view the index" do
    viewer = users(:regular_user)
    viewer.domain_roles.create!(domain: :music, permission_level: :viewer)
    sign_in_as(viewer, stub_auth: true)

    get admin_album_descriptions_path(@album)
    assert_response :success
  end

  test "should deny a music domain viewer from creating a description" do
    viewer = users(:regular_user)
    viewer.domain_roles.create!(domain: :music, permission_level: :viewer)
    sign_in_as(viewer, stub_auth: true)

    assert_no_difference "Description.count" do
      post admin_album_descriptions_path(@album), params: {
        description: {content: "No.", source: "manual"}
      }
    end
    assert_redirected_to music_root_path
  end

  test "should allow a music domain editor to update a music description" do
    sign_in_as(users(:contractor_user), stub_auth: true)

    patch admin_description_path(@description), params: {
      description: {content: "Edited by editor."}
    }

    assert_equal "Edited by editor.", @description.reload.content
  end
end
