require "test_helper"

module Admin
  module Books
    class RankingArchivesControllerTest < ActionDispatch::IntegrationTest
      setup do
        @admin_user = users(:admin_user)
        @regular_user = users(:regular_user)
        @archive = ranking_archives(:books_january_2027)
        @hidden = ranking_archives(:books_hidden_legacy)
        @before_ids = @archive.item_ids
        host! Rails.application.config.domains[:books]
      end

      test "index lists archives, hidden ones included" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_ranking_archives_path
        assert_response :success
        ids = assigned_archives.map(&:id)
        assert_includes ids, @archive.id
        assert_includes ids, @hidden.id
      end

      test "index does not load the arrays" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_ranking_archives_path
        row = assigned_archives.first
        assert_raises(ActiveModel::MissingAttributeError) { row.item_ids }
      end

      test "show renders for a hidden archive" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_ranking_archive_path(@hidden)
        assert_response :success
      end

      test "show renders for a visible archive" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_ranking_archive_path(@archive)
        assert_response :success
      end

      test "show renders when every archived book is gone" do
        sign_in_as(@admin_user, stub_auth: true)
        ::Books::Book.where(id: @archive.item_ids).find_each(&:destroy!)
        get admin_books_ranking_archive_path(@archive)
        assert_response :success
      end

      test "edit renders" do
        sign_in_as(@admin_user, stub_auth: true)
        get edit_admin_books_ranking_archive_path(@archive)
        assert_response :success
      end

      test "update changes name, slug, description and hidden" do
        sign_in_as(@admin_user, stub_auth: true)
        patch admin_books_ranking_archive_path(@archive), params: {books_ranking_archive: {name: "Renamed", slug: "renamed", description: "Words", hidden: "1"}}
        assert_redirected_to admin_books_ranking_archive_path(@archive)
        @archive.reload
        assert_equal ["Renamed", "renamed", "Words", true], [@archive.name, @archive.slug, @archive.description, @archive.hidden]
      end

      test "update ignores ranked data in the params" do
        sign_in_as(@admin_user, stub_auth: true)
        patch admin_books_ranking_archive_path(@archive), params: {books_ranking_archive: {name: "N", item_ids: [1], items_count: 1}}
        assert_redirected_to admin_books_ranking_archive_path(@archive)
        @archive.reload
        assert_equal [@before_ids, 2, "N"], [@archive.item_ids, @archive.items_count, @archive.name]
      end

      test "a taken slug re-renders the form with 422 and changes nothing" do
        sign_in_as(@admin_user, stub_auth: true)
        patch admin_books_ranking_archive_path(@archive), params: {books_ranking_archive: {name: "Changed", slug: @hidden.slug}}
        assert_response :unprocessable_entity
        @archive.reload
        assert_equal ["January 2027", "january-2027"], [@archive.name, @archive.slug]
      end

      test "a malformed slug re-renders the form with 422 and changes nothing" do
        sign_in_as(@admin_user, stub_auth: true)
        patch admin_books_ranking_archive_path(@archive), params: {books_ranking_archive: {name: "Changed", slug: "My Slug!"}}
        assert_response :unprocessable_entity
        @archive.reload
        assert_equal ["January 2027", "january-2027"], [@archive.name, @archive.slug]
      end

      test "destroy deletes the archive" do
        sign_in_as(@admin_user, stub_auth: true)
        assert_difference("::Books::RankingArchive.count", -1) do
          delete admin_books_ranking_archive_path(@archive)
        end
        assert_redirected_to admin_books_ranking_archives_path
      end

      test "a signed-out visitor is redirected to the books root" do
        get admin_books_ranking_archives_path
        assert_redirected_to books_root_path
      end

      test "a regular user is redirected to the books root" do
        sign_in_as(@regular_user, stub_auth: true)
        get admin_books_ranking_archives_path
        assert_redirected_to books_root_path
      end

      test "a regular user cannot update or destroy" do
        sign_in_as(@regular_user, stub_auth: true)
        patch admin_books_ranking_archive_path(@archive), params: {books_ranking_archive: {name: "Nope"}}
        assert_redirected_to books_root_path
        assert_no_difference("::Books::RankingArchive.count") do
          delete admin_books_ranking_archive_path(@archive)
        end
        assert_redirected_to books_root_path
        assert_equal "January 2027", @archive.reload.name
      end

      test "a books viewer can read but not update or destroy" do
        @regular_user.domain_roles.create!(domain: :books, permission_level: :viewer)
        sign_in_as(@regular_user, stub_auth: true)
        get admin_books_ranking_archives_path
        assert_response :success
        patch admin_books_ranking_archive_path(@archive), params: {books_ranking_archive: {name: "Nope"}}
        assert_redirected_to books_root_path
        assert_no_difference("::Books::RankingArchive.count") do
          delete admin_books_ranking_archive_path(@archive)
        end
        assert_redirected_to books_root_path
        assert_equal "January 2027", @archive.reload.name
      end

      private

      def assigned_archives
        controller.view_assigns["archives"].to_a
      end
    end
  end
end
