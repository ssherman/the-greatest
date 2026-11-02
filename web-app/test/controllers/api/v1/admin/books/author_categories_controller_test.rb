require "test_helper"

module Api
  module V1
    module Admin
      module Books
        class AuthorCategoriesControllerTest < ActionDispatch::IntegrationTest
          WRITE = ApiTokenSecrets::ADMIN

          setup do
            host! "dev-new.thegreatestbooks.org"
            @author = books_authors(:tolstoy)
            @subject = categories(:books_politics_subject)
          end

          def json = response.parsed_body.deep_symbolize_keys

          def tag(category_id, token: WRITE, id: @author.id)
            post "/api/v1/admin/authors/#{id}/categories", params: {category_id: category_id}, as: :json, headers: bearer(token)
          end

          test "tagging then untagging an author" do
            tag(@subject.id)
            assert_api_response_conform(status: 200, api: :admin)
            assert_equal [@subject.id], json[:data].map { |c| c[:id] }
            assert_equal "admin", json[:data].first[:source]

            delete "/api/v1/admin/authors/#{@author.id}/categories/#{@subject.id}", headers: bearer(WRITE)
            assert_api_response_conform(status: 200, api: :admin)
            assert_empty json[:data]
            assert_not @author.category_items.exists?
          end

          test "untagging a category the author lacks is 404, an unknown author is 404" do
            delete "/api/v1/admin/authors/#{@author.id}/categories/#{@subject.id}", headers: bearer(WRITE)
            assert_api_response_conform(status: 404, api: :admin)

            tag(@subject.id, id: 999_999_999)
            assert_api_response_conform(status: 404, api: :admin)
            assert_includes json[:detail], "author"
          end

          test "a music category is refused" do
            tag(categories(:music_rock_genre).id)
            assert_api_response_conform(status: 422, api: :admin)
          end

          test "a read-only token is refused" do
            tag(@subject.id, token: ApiTokenSecrets::ADMIN_READ)
            assert_api_response_conform(status: 403, api: :admin)
            assert_equal "insufficient_scope", json[:code]
          end

          test "an owner the author policy refuses gets forbidden naming the author" do
            ::Books::AuthorPolicy.any_instance.stubs(:update?).returns(false)

            tag(@subject.id)
            assert_api_response_conform(status: 403, api: :admin)
            assert_includes json[:detail], "author"
          end
        end
      end
    end
  end
end
