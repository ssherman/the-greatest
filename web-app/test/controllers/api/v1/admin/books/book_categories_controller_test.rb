require "test_helper"

module Api
  module V1
    module Admin
      module Books
        class BookCategoriesControllerTest < ActionDispatch::IntegrationTest
          WRITE = ApiTokenSecrets::ADMIN
          READ = ApiTokenSecrets::ADMIN_READ

          setup do
            host! "dev-new.thegreatestbooks.org"
            @book = books_books(:war_and_peace)
            @politics = categories(:books_politics_subject)
          end

          def json = response.parsed_body.deep_symbolize_keys

          def tag(body, token: WRITE, id: @book.id)
            post "/api/v1/admin/books/#{id}/categories", params: body, as: :json, headers: bearer(token)
          end

          def untag(category_id, token: WRITE, id: @book.id)
            delete "/api/v1/admin/books/#{id}/categories/#{category_id}", headers: bearer(token)
          end

          def location(name, parent: nil)
            ::Books::Category.create!(name: name, category_type: :location, parent: parent)
          end

          test "tagging a book lists the category as an admin link, sorted by name" do
            tag({category_id: @politics.id})
            assert_api_response_conform(status: 200, api: :admin)

            names = json[:data].map { |c| c[:name] }
            assert_equal names.sort, names
            entry = json[:data].find { |c| c[:id] == @politics.id }
            assert_equal [@politics.slug, "subject", "admin"], [entry[:slug], entry[:category_type], entry[:source]]
            assert_equal %w[id slug name category_type source], entry.keys.map(&:to_s)
          end

          test "tagging twice succeeds and leaves one row" do
            tag({category_id: @politics.id})
            tag({category_id: @politics.id.to_s})
            assert_api_response_conform(status: 200, api: :admin)

            assert_equal 1, @book.category_items.where(category_id: @politics.id).count
          end

          test "tagging with a merged category is refused naming the canonical id" do
            source = ::Books::Category.create!(name: "Old Politics", category_type: :subject)
            source.update_columns(deleted: true, merged_into_id: @politics.id)

            tag({category_id: source.id})
            assert_api_response_conform(status: 422, api: :admin)

            assert_equal "unprocessable", json[:code]
            assert_includes json[:detail], "(#{@politics.id})"
            assert_not @book.category_items.exists?(category_id: source.id)
          end

          test "a music category is refused as another section" do
            tag({category_id: categories(:music_rock_genre).id})
            assert_api_response_conform(status: 422, api: :admin)

            assert_includes json[:detail], "different section"
          end

          test "untagging removes the link and returns the rest" do
            untag(categories(:books_novels_genre).id)
            assert_api_response_conform(status: 200, api: :admin)

            assert_not_includes json[:data].map { |c| c[:id] }, categories(:books_novels_genre).id
            assert_not @book.category_items.exists?(category_id: categories(:books_novels_genre).id)
          end

          test "untagging an inherited category is refused naming the location" do
            parent = location("Zedland")
            child = location("Zedtown", parent: parent)
            tag({category_id: child.id})
            assert_equal "inherited", CategoryItem.find_by(item: @book, category: parent).source

            untag(parent.id)
            assert_api_response_conform(status: 422, api: :admin)

            assert_includes json[:detail], "Zedtown"
            assert CategoryItem.exists?(item: @book, category: parent)
          end

          test "untagging a category the book lacks is 404" do
            untag(@politics.id)
            assert_api_response_conform(status: 404, api: :admin)

            assert_equal "not_found", json[:code]
          end

          test "an unknown book or category is 404 naming which" do
            tag({category_id: @politics.id}, id: 999_999_999)
            assert_api_response_conform(status: 404, api: :admin)
            assert_includes json[:detail], "book"

            tag({category_id: 999_999_999})
            assert_api_response_conform(status: 404, api: :admin)
            assert_includes json[:detail], "category"

            untag(999_999_999)
            assert_equal 404, response.status
          end

          test "a malformed or missing category_id is 400" do
            ["abc", "0x1A", 0, -1, 1.5, nil, [1]].each do |value|
              tag({category_id: value})
              assert_api_response_conform(status: 400, api: :admin)
              assert_equal "invalid_parameter", json[:code], value.inspect
            end

            tag({})
            assert_equal 400, response.status
          end

          test "a read-only token is refused with insufficient_scope" do
            tag({category_id: @politics.id}, token: READ)
            assert_api_response_conform(status: 403, api: :admin)
            assert_equal "insufficient_scope", json[:code]

            untag(categories(:books_novels_genre).id, token: READ)
            assert_equal "insufficient_scope", json[:code]
            assert @book.category_items.exists?(category_id: categories(:books_novels_genre).id)
          end

          test "an owner the book policy refuses gets forbidden naming the book" do
            ::Books::BookPolicy.any_instance.stubs(:update?).returns(false)

            tag({category_id: @politics.id})
            assert_api_response_conform(status: 403, api: :admin)

            assert_equal "forbidden", json[:code]
            assert_includes json[:detail], "book"
            assert_not @book.category_items.exists?(category_id: @politics.id)
          end

          test "an owner the category policy refuses gets forbidden naming the category" do
            ::Books::CategoryPolicy.any_instance.stubs(:update?).returns(false)

            untag(categories(:books_novels_genre).id)
            assert_api_response_conform(status: 403, api: :admin)

            assert_equal "forbidden", json[:code]
            assert_includes json[:detail], "category"
          end

          test "a successful link and unlink each write one structured log line" do
            Rails.logger.stubs(:info)
            Rails.logger.expects(:info).with(regexp_matches(/event=api_admin_category_link action=link token_id=\d+ user_id=\d+ item_type=Books::Book item_id=#{@book.id} category_id=#{@politics.id}\z/)).once
            tag({category_id: @politics.id})

            Rails.logger.expects(:info).with(regexp_matches(/event=api_admin_category_link action=unlink .*item_id=#{@book.id} category_id=#{@politics.id}\z/)).once
            untag(@politics.id)
          end

          test "a refused link writes no log line" do
            Rails.logger.stubs(:info)
            Rails.logger.expects(:info).with(regexp_matches(/api_admin_category_link/)).never
            tag({category_id: categories(:music_rock_genre).id})
          end
        end
      end
    end
  end
end
