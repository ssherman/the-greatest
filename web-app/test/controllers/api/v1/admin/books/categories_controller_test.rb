require "test_helper"

module Api
  module V1
    module Admin
      module Books
        class CategoriesControllerTest < ActionDispatch::IntegrationTest
          READ = ApiTokenSecrets::ADMIN_READ

          setup do
            host! "dev-new.thegreatestbooks.org"
            @novels = categories(:books_novels_genre)
          end

          def json = response.parsed_body.deep_symbolize_keys

          def names = json[:data].map { |c| c[:name] }

          def merged_category
            ::Books::Category.create!(name: "Old Novels", category_type: :genre).tap do |source|
              source.update_columns(deleted: true, merged_into_id: @novels.id)
            end
          end

          test "lists active books categories by name when q is absent" do
            get "/api/v1/admin/categories", params: {per_page: 100}, headers: bearer(READ)
            assert_api_response_conform(status: 200, api: :admin)

            expected = ::Books::Category.active.order(:name).pluck(:name)
            assert_equal expected, names
            assert_not_includes names, "Retired Genre"
          end

          test "q matches a name substring and an alternative-name substring" do
            @novels.update!(alternative_names: ["Prose Fiction"])

            get "/api/v1/admin/categories", params: {q: "ovel"}, headers: bearer(READ)
            assert_includes names, "Novels"

            get "/api/v1/admin/categories", params: {q: "prose fic"}, headers: bearer(READ)
            assert_api_response_conform(status: 200, api: :admin)
            assert_equal ["Novels"], names
          end

          test "q ranks exact above prefix above substring" do
            ::Books::Category.create!(name: "Great Fiction", category_type: :genre)
            ::Books::Category.create!(name: "Fiction Extra", category_type: :genre)

            get "/api/v1/admin/categories", params: {q: "fiction"}, headers: bearer(READ)
            assert_equal ["Fiction", "Fiction Extra", "Great Fiction"], names.first(3)
          end

          test "q ranks a word-start match above a mere contains match" do
            ::Books::Category.create!(name: "Scapocalypse", category_type: :genre)
            ::Books::Category.create!(name: "Post-Apocalyptic", category_type: :genre)

            get "/api/v1/admin/categories", params: {q: "apoc"}, headers: bearer(READ)
            assert_equal ["Post-Apocalyptic", "Scapocalypse"], names
          end

          test "book_count is the ranked books on the primary configuration" do
            rc = ranking_configurations(:books_global)
            RankedItem.create!(item: books_books(:war_and_peace), ranking_configuration: rc, rank: 1, score: 100)
            RankedItem.create!(item: books_books(:crime_and_punishment), ranking_configuration: rc, rank: 2, score: 90)
            CategoryItem.where(category: categories(:books_politics_subject)).delete_all
            [:war_and_peace, :crime_and_punishment, :of_mice_and_men].each do |book|
              CategoryItem.create!(category: categories(:books_politics_subject), item: books_books(book))
            end

            get "/api/v1/admin/categories", params: {q: "Politics"}, headers: bearer(READ)
            assert_api_response_conform(status: 200, api: :admin)
            assert_equal [2], json[:data].map { |c| c[:book_count] }

            get "/api/v1/admin/categories/#{categories(:books_politics_subject).id}", headers: bearer(READ)
            assert_equal 2, json[:data][:book_count]
          end

          test "the number of queries does not grow with the page size" do
            get "/api/v1/admin/categories", params: {per_page: 1}, headers: bearer(READ)
            small = capture_sql { get "/api/v1/admin/categories", params: {per_page: 1}, headers: bearer(READ) }.size
            large = capture_sql { get "/api/v1/admin/categories", params: {per_page: 100}, headers: bearer(READ) }.size

            assert_operator ::Books::Category.active.count, :>, 5
            assert_equal small, large
          end

          test "q is treated literally, not as a LIKE pattern" do
            get "/api/v1/admin/categories", params: {q: "%"}, headers: bearer(READ)
            assert_empty json[:data]
          end

          test "status filters active, deleted, merged and all" do
            merged = merged_category
            deleted = categories(:books_deleted_genre)

            get "/api/v1/admin/categories", params: {status: "merged"}, headers: bearer(READ)
            assert_api_response_conform(status: 200, api: :admin)
            assert_equal [merged.id], json[:data].map { |c| c[:id] }
            assert_equal({id: @novels.id, name: "Novels"}, json[:data].first[:merged_into])

            get "/api/v1/admin/categories", params: {status: "deleted"}, headers: bearer(READ)
            assert_equal [deleted.id], json[:data].map { |c| c[:id] }
            assert_nil json[:data].first[:merged_into]

            get "/api/v1/admin/categories", params: {status: "all", per_page: 100}, headers: bearer(READ)
            ids = json[:data].map { |c| c[:id] }
            assert_includes ids, merged.id
            assert_includes ids, deleted.id
            assert_includes ids, @novels.id
          end

          test "an unknown status is a 400" do
            get "/api/v1/admin/categories", params: {status: "bogus"}, headers: bearer(READ)
            assert_api_response_conform(status: 400, api: :admin)
          end

          test "type filters to one type; a type not valid for books is a 400" do
            theme = ::Books::Category.create!(name: "Redemption", category_type: :theme)

            get "/api/v1/admin/categories", params: {type: "theme"}, headers: bearer(READ)
            assert_api_response_conform(status: 200, api: :admin)
            assert_equal [theme.id], json[:data].map { |c| c[:id] }

            get "/api/v1/admin/categories", params: {type: "game_mode"}, headers: bearer(READ)
            assert_api_response_conform(status: 400, api: :admin)
          end

          test "items carry the admin fields and per-type link counts" do
            linked = ::Books::Category.create!(name: "Linked Zed", category_type: :genre)
            CategoryItem.create!(category: linked, item: books_books(:war_and_peace))
            CategoryItem.create!(category: linked, item: books_authors(:tolstoy))
            child = ::Books::Category.create!(name: "Tiny Zed", category_type: :genre, parent_id: linked.id)

            get "/api/v1/admin/categories", params: {q: "Zed"}, headers: bearer(READ)
            assert_api_response_conform(status: 200, api: :admin)

            row = json[:data].find { |c| c[:id] == linked.id }
            assert_equal [1, 1, 1, false], row.values_at(:book_link_count, :author_link_count, :children_count, :deleted)
            tiny = json[:data].find { |c| c[:id] == child.id }
            assert_equal [0, 0, 0], tiny.values_at(:book_link_count, :author_link_count, :children_count)
            assert_equal({id: linked.id, slug: "linked-zed", name: "Linked Zed"}, tiny[:parent])
          end

          test "a deleted parent still shows on the admin list" do
            parent = categories(:books_deleted_genre)
            child = ::Books::Category.create!(name: "Orphan Kid", category_type: :genre)
            child.update_columns(parent_id: parent.id)

            get "/api/v1/admin/categories", params: {q: "Orphan"}, headers: bearer(READ)
            assert_equal parent.id, json[:data].first[:parent][:id]
          end

          test "pagination links carry q, type and status" do
            get "/api/v1/admin/categories", params: {q: "a", type: "genre", status: "all", per_page: 1}, headers: bearer(READ)
            next_link = json[:links][:next]

            assert_includes next_link, "q=a"
            assert_includes next_link, "type=genre"
            assert_includes next_link, "status=all"
            get next_link, headers: bearer(READ)
            assert_api_response_conform(status: 200, api: :admin)
          end

          test "a member token is refused and a viewer token is allowed" do
            get "/api/v1/admin/categories", headers: bearer(ApiTokenSecrets::MEMBER)
            assert_api_response_conform(status: 403, api: :admin)
            assert_equal "insufficient_scope", json[:code]

            get "/api/v1/admin/categories", headers: bearer(READ)
            assert_response :success
          end

          test "show returns children and the ancestor chain for a nested location" do
            country = ::Books::Category.create!(name: "Freedonia", category_type: :location)
            state = ::Books::Category.create!(name: "Fredland", category_type: :location, parent_id: country.id)
            city = ::Books::Category.create!(name: "Fredville", category_type: :location, parent_id: state.id)

            get "/api/v1/admin/categories/#{state.id}", headers: bearer(READ)
            assert_api_response_conform(status: 200, api: :admin)
            assert_equal [country.id], json[:data][:ancestors].map { |c| c[:id] }
            assert_equal [{id: city.id, slug: city.slug, name: "Fredville"}], json[:data][:children]

            get "/api/v1/admin/categories/#{city.id}", headers: bearer(READ)
            assert_equal [country.id, state.id], json[:data][:ancestors].map { |c| c[:id] }
            assert_equal [], json[:data][:children]
          end

          test "show has an empty ancestor chain for a non-location and serves deleted and merged rows" do
            get "/api/v1/admin/categories/#{@novels.id}", headers: bearer(READ)
            assert_equal [], json[:data][:ancestors]

            merged = merged_category
            get "/api/v1/admin/categories/#{merged.id}", headers: bearer(READ)
            assert_equal [true, @novels.id], [json[:data][:deleted], json[:data][:merged_into][:id]]

            get "/api/v1/admin/categories/#{categories(:books_deleted_genre).id}", headers: bearer(READ)
            assert_response :success
          end

          test "show is a 404 for an unknown id and for another site's category" do
            get "/api/v1/admin/categories/999999999", headers: bearer(READ)
            assert_api_response_conform(status: 404, api: :admin)

            get "/api/v1/admin/categories/#{categories(:games_action_genre).id}", headers: bearer(READ)
            assert_response :not_found
          end

          test "show refuses a member token" do
            get "/api/v1/admin/categories/#{@novels.id}", headers: bearer(ApiTokenSecrets::MEMBER)
            assert_api_response_conform(status: 403, api: :admin)
          end

          WRITE_BODY = {name: "Magic Realism", category_type: "genre", description: "Fabulist", alternative_names: ["Magical Realism"]}.freeze

          def write_token_for(user)
            ::Services::Api::Tokens.generate(user: user, name: "writer", scopes: ["books:admin:write"], expires_at: 30.days.from_now).data[:secret]
          end

          def write_token
            @write_token ||= begin
              user = User.create!(email: "cat-editor@example.com", name: "Cat Editor")
              user.domain_roles.create!(domain: :books, permission_level: :editor)
              write_token_for(user)
            end
          end

          def create_category(body, token: write_token) = post("/api/v1/admin/categories", params: body, as: :json, headers: bearer(token))

          def update_category(id, body, token: write_token) = patch("/api/v1/admin/categories/#{id}", params: body, as: :json, headers: bearer(token))

          test "create returns 201 with the full shape" do
            assert_difference -> { ::Books::Category.count }, 1 do
              create_category(WRITE_BODY.merge(ignored_key: "x"))
            end
            assert_api_response_conform(status: 201, api: :admin)

            assert_equal "Magic Realism", json[:data][:name]
            assert_equal ["Magical Realism"], json[:data][:alternative_names]
            assert_equal "genre", json[:data][:category_type]
          end

          test "a merge-scoped token can also write" do
            create_category(WRITE_BODY, token: ApiTokenSecrets::ADMIN)
            assert_api_response_conform(status: 201, api: :admin)
          end

          test "a duplicate name is 422 naming the existing id" do
            create_category({name: "novels"})
            assert_api_response_conform(status: 422, api: :admin)

            assert_includes json[:detail], "Another category already uses that name: #{@novels.id} (name)"
          end

          test "a duplicate alias is 422 naming the id and kind" do
            @novels.update!(alternative_names: ["Prose Fiction"])

            create_category({name: "Prose fiction"})
            assert_includes json[:detail], "#{@novels.id} (alias)"
          end

          test "a case-only rename is allowed" do
            update_category(@novels.id, {name: "NOVELS"})
            assert_api_response_conform(status: 200, api: :admin)
            assert_equal "NOVELS", @novels.reload.name
          end

          test "update keeps the id and changes only the keys sent" do
            update_category(@novels.id, {description: "New words"})
            assert_api_response_conform(status: 200, api: :admin)

            assert_equal @novels.id, json[:data][:id]
            assert_equal "New words", @novels.reload.description
            assert_equal "Novels", @novels.name
          end

          test "a parent that makes a cycle is 422 with the model message" do
            france = categories(:books_france_location)
            child = ::Books::Category.create!(name: "Paris", category_type: :location, parent: france)

            update_category(france.id, {parent_id: child.id})
            assert_api_response_conform(status: 422, api: :admin)
            assert_includes json[:detail], "cycle"
          end

          test "editing a merged or deleted category is 422" do
            update_category(merged_category.id, {description: "x"})
            assert_api_response_conform(status: 422, api: :admin)

            update_category(categories(:books_deleted_genre).id, {description: "x"})
            assert_response :unprocessable_entity
          end

          test "bad bodies are 400" do
            create_category({name: "Zed", category_type: "player_perspective"})
            assert_api_response_conform(status: 400, api: :admin)

            create_category({name: "Zed", alternative_names: "nope"})
            assert_response :bad_request

            update_category(@novels.id, {parent_id: "0x1A"})
            assert_response :bad_request

            update_category(@novels.id, {parent_id: 0})
            assert_response :bad_request
          end

          test "names are stored stripped, so a padded name cannot mint a twin" do
            create_category({name: "Zed "})
            assert_equal "Zed", ::Books::Category.find(json[:data][:id]).name

            create_category({name: "Zed"})
            assert_response :unprocessable_entity
          end

          test "a legacy row with stray whitespace blocks the same name" do
            ::Books::Category.create!(name: "Zed", category_type: :genre).update_columns(name: "Zed ")

            create_category({name: "zed"})
            assert_response :unprocessable_entity
          end

          test "non-string name or description is 400" do
            create_category({name: ["a"]})
            assert_response :bad_request
            update_category(@novels.id, {description: {a: 1}})
            assert_response :bad_request
          end

          test "create without a name is 400" do
            create_category({category_type: "genre"})
            assert_api_response_conform(status: 400, api: :admin)
            create_category({name: "  "})
            assert_response :bad_request
          end

          test "a missing parent is 422" do
            update_category(@novels.id, {parent_id: 999_999_999})
            assert_response :unprocessable_entity
          end

          test "an unknown id is 404" do
            update_category(999_999_999, {description: "x"})
            assert_api_response_conform(status: 404, api: :admin)
          end

          test "a read-only or member token cannot write" do
            create_category(WRITE_BODY, token: READ)
            assert_api_response_conform(status: 403, api: :admin)
            update_category(@novels.id, {description: "x"}, token: ApiTokenSecrets::MEMBER)
            assert_response :forbidden
            assert_not_equal "x", @novels.reload.description
          end

          test "a write-scoped token also reads" do
            get "/api/v1/admin/categories", headers: bearer(write_token)
            assert_response :ok
          end

          test "a write token whose owner was demoted to viewer is 403" do
            secret = write_token
            User.find_by!(email: "cat-editor@example.com").domain_roles.find_by!(domain: :books).update!(permission_level: :viewer)

            create_category(WRITE_BODY, token: secret)
            assert_response :forbidden
            assert_not ::Books::Category.exists?(name: "Magic Realism")
          end

          test "an action with no mapped scope fails closed" do
            klass = Class.new(::Api::V1::BaseController) do
              require_scopes show: "books:admin:read"
            end
            controller = klass.new
            controller.stubs(:action_name).returns("index")
            controller.stubs(:current_principal).returns(stub(scope?: true))

            assert_raises(RuntimeError) { controller.send(:require_scope!) }
          end
        end
      end
    end
  end
end
