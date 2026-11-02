require "test_helper"

module Api
  module V1
    module Admin
      module Books
        # POST /admin/categories/:id/merge and DELETE /admin/categories/:id.
        class CategoryDestructiveTest < ActionDispatch::IntegrationTest
          MERGE = ApiTokenSecrets::ADMIN

          setup do
            host! "dev-new.thegreatestbooks.org"
            ::Books::Category.stubs(:protected_ids).returns([categories(:books_fiction_genre).id])
            @target = ::Books::Category.create!(name: "Target Genre", category_type: :genre)
            @sources = %w[Alpha Beta Gamma].map { |n| ::Books::Category.create!(name: "#{n} Source", category_type: :genre) }
            @books = [:war_and_peace, :crime_and_punishment, :of_mice_and_men].map { |b| books_books(b) }
            @sources.zip(@books).each { |category, book| CategoryItem.create!(category: category, item: book, source: :admin) }
          end

          def json = response.parsed_body.deep_symbolize_keys

          def merge(body, token: MERGE, id: @target.id)
            post "/api/v1/admin/categories/#{id}/merge", params: body, as: :json, headers: bearer(token)
          end

          def destroy_category(id, query = "", token: MERGE)
            delete "/api/v1/admin/categories/#{id}#{query}", headers: bearer(token)
          end

          def source_ids = @sources.map(&:id)

          def refuse_delete_of(refused)
            ::Books::CategoryPolicy.stubs(:new).with { |_user, record| record != refused }
              .returns(stub_everything(destroy?: true))
            ::Books::CategoryPolicy.stubs(:new).with { |_user, record| record == refused }
              .returns(stub_everything(destroy?: false))
          end

          test "merging three sources moves their links and soft-deletes each with merged_into" do
            merge({source_ids: source_ids})
            assert_api_response_conform(status: 200, api: :admin)

            assert_equal source_ids, json[:data][:merged]
            assert_equal @target.id, json[:data][:target][:id]
            assert_equal 3, json[:data][:target][:book_link_count]
            assert_equal false, json[:meta][:dry_run]
            @sources.each do |source|
              source.reload
              assert source.deleted?
              assert_equal @target.id, source.merged_into_id
            end
            assert_equal @books.map(&:id).sort, CategoryItem.where(category: @target).pluck(:item_id).sort
          end

          test "dry run changes nothing and reports each source" do
            ::Categories::Merger.any_instance.expects(:merge).never

            merge({source_ids: source_ids, dry_run: true})
            assert_api_response_conform(status: 200, api: :admin)

            assert_equal true, json[:meta][:dry_run]
            assert_equal source_ids, json[:data][:sources].map { |s| s[:id] }
            assert_equal({id: @sources.first.id, name: "Alpha Source", book_link_count: 1, author_link_count: 0}, json[:data][:sources].first)
            assert_equal @target.id, json[:data][:target][:id]
            assert_equal 0, CategoryItem.where(category: @target).count
            assert_not @sources.first.reload.deleted?
          end

          test "a protected category among the sources is 422 listing it and nothing merges" do
            fiction = categories(:books_fiction_genre)

            merge({source_ids: [@sources.first.id, fiction.id, @sources.last.id]})
            assert_api_response_conform(status: 422, api: :admin)

            assert_equal "unprocessable", json[:code]
            assert_includes json[:detail], "#{fiction.id}: Fiction, Nonfiction, Poetry"
            assert_not_includes json[:detail], "#{@sources.first.id}:"
            @sources.each { |s| assert_not s.reload.deleted? }
            assert_equal 0, CategoryItem.where(category: @target).count
          end

          test "every refused source is listed" do
            fiction = categories(:books_fiction_genre)
            retired = categories(:books_deleted_genre)

            merge({source_ids: [fiction.id, retired.id]})

            assert_includes json[:detail], "#{fiction.id}:"
            assert_includes json[:detail], "#{retired.id}: Deleted categories can't be merged."
          end

          test "the target among source_ids is 400" do
            merge({source_ids: [@sources.first.id, @target.id]})
            assert_api_response_conform(status: 400, api: :admin)
            assert_not @sources.first.reload.deleted?
          end

          test "a duplicate source id is 400" do
            merge({source_ids: [@sources.first.id, @sources.first.id]})
            assert_api_response_conform(status: 400, api: :admin)
            assert_not @sources.first.reload.deleted?
          end

          test "51 sources is 400, and so are empty, non-array and malformed ids" do
            merge({source_ids: (1..51).to_a})
            assert_response :bad_request
            merge({source_ids: []})
            assert_response :bad_request
            merge({source_ids: "5"})
            assert_response :bad_request
            merge({})
            assert_response :bad_request
            merge({source_ids: [@sources.first.id, "0x1A"]})
            assert_response :bad_request
            merge({source_ids: [0]})
            assert_response :bad_request
          end

          test "a missing source is 404 naming the first missing id" do
            merge({source_ids: [@sources.first.id, 999_999_998, 999_999_999]})
            assert_api_response_conform(status: 404, api: :admin)
            assert_includes json[:detail], "999999998"
            assert_not @sources.first.reload.deleted?
          end

          test "a missing target and another site's category are 404" do
            merge({source_ids: source_ids}, id: 999_999_999)
            assert_response :not_found

            merge({source_ids: [categories(:music_rock_genre).id]})
            assert_response :not_found
          end

          test "a policy refusal on one source is 403 naming it and nothing merges" do
            refuse_delete_of(@sources.second)

            merge({source_ids: source_ids})
            assert_api_response_conform(status: 403, api: :admin)

            assert_equal "forbidden", json[:code]
            assert_includes json[:detail], @sources.second.id.to_s
            @sources.each { |s| assert_not s.reload.deleted? }
          end

          test "a failure part way stops, reports the split, and keeps the first merge" do
            # The counter runs inside each merge's transaction: the second raises
            # and rolls back, the first is real.
            ::Categories::ItemCounter.stubs(:call).returns(nil).then.raises(RuntimeError, "boom")

            merge({source_ids: source_ids})
            assert_api_response_conform(status: 422, api: :admin)

            assert_equal [@sources.first.id], json[:merged]
            assert_equal({id: @sources.second.id, message: "boom"}, json[:failed])
            assert_equal [@sources.third.id], json[:not_attempted]
            assert @sources.first.reload.deleted?
            assert_not @sources.second.reload.deleted?
            assert_not @sources.third.reload.deleted?
          end

          test "a post-commit error leaves the source merged and reported as such" do
            ::Categories::ItemReindexer.stubs(:queue_items).raises(RuntimeError, "queue down")
            Rails.logger.stubs(:info)
            Rails.logger.expects(:info).with(regexp_matches(/event=api_admin_category_merge outcome=succeeded .*post_commit_error="queue down"/)).times(3)

            merge({source_ids: source_ids})
            assert_api_response_conform(status: 200, api: :admin)

            assert_equal source_ids, json[:data][:merged]
            assert_equal source_ids, json[:data][:post_commit_errors].map { |e| e[:id] }
            assert_equal "queue down", json[:data][:post_commit_errors].first[:message]
            @sources.each { |s| assert s.reload.deleted? }
          end

          test "a post-commit error then a genuine failure reports both" do
            ::Categories::ItemReindexer.stubs(:queue_items).raises(RuntimeError, "queue down")
            ::Categories::ItemCounter.stubs(:call).returns(nil).then.raises(RuntimeError, "boom")

            merge({source_ids: source_ids})
            assert_api_response_conform(status: 422, api: :admin)

            assert_equal [@sources.first.id], json[:merged]
            assert_equal @sources.first.id, json[:post_commit_errors].first[:id]
            assert_equal @sources.second.id, json[:failed][:id]
            assert_equal [@sources.third.id], json[:not_attempted]
          end

          test "dry_run must be strictly true or false on merge and delete" do
            ["", "yes", "False", "1", 1, nil].each do |bad|
              merge({source_ids: source_ids, dry_run: bad})
              assert_response :bad_request, "merge dry_run=#{bad.inspect}"
            end
            ["", "yes", "False", "1"].each do |bad|
              destroy_category(@sources.first.id, "?dry_run=#{bad}")
              assert_response :bad_request, "delete dry_run=#{bad.inspect}"
            end
            assert_not @sources.first.reload.deleted?

            merge({source_ids: source_ids, dry_run: "true"})
            assert_equal true, json[:meta][:dry_run]
            destroy_category(@sources.first.id, "?dry_run=true")
            assert_equal true, json[:meta][:dry_run]
            merge({source_ids: source_ids, dry_run: false})
            assert_equal false, json[:meta][:dry_run]
          end

          test "a real merge logs one line per source" do
            Rails.logger.stubs(:info)
            Rails.logger.expects(:info).with(regexp_matches(/event=api_admin_category_merge outcome=succeeded .*source_id=\d+ target_id=#{@target.id}/)).times(3)

            merge({source_ids: source_ids})
          end

          test "a failed merge logs the failure" do
            ::Categories::ItemCounter.stubs(:call).raises(RuntimeError, "boom")
            Rails.logger.stubs(:info)
            Rails.logger.expects(:info).with(regexp_matches(/event=api_admin_category_merge outcome=failed .*source_id=#{@sources.first.id}/)).once

            merge({source_ids: source_ids})
          end

          test "a write-only token cannot merge or delete" do
            user = User.create!(email: "cat-writer@example.com", name: "Writer")
            user.domain_roles.create!(domain: :books, permission_level: :editor)
            secret = ::Services::Api::Tokens.generate(user: user, name: "writer", scopes: ["books:admin:write"], expires_at: 30.days.from_now).data[:secret]

            merge({source_ids: source_ids}, token: secret)
            assert_response :forbidden
            assert_equal "insufficient_scope", json[:code]
            destroy_category(@sources.first.id, token: secret)
            assert_response :forbidden
            assert_equal "insufficient_scope", json[:code]
            assert_not @sources.first.reload.deleted?
          end

          test "delete dry run reports link counts and changes nothing" do
            ::Categories::Deleter.expects(:new).never

            destroy_category(@sources.first.id, "?dry_run=true")
            assert_api_response_conform(status: 200, api: :admin)

            assert_equal 1, json[:data][:book_links_removed]
            assert_equal 0, json[:data][:author_links_removed]
            assert_equal @sources.first.id, json[:data][:category][:id]
            assert_equal true, json[:meta][:dry_run]
            assert_not @sources.first.reload.deleted?
            assert_equal 1, CategoryItem.where(category: @sources.first).count
          end

          test "delete removes the links and marks the category deleted" do
            destroy_category(@sources.first.id)
            assert_api_response_conform(status: 200, api: :admin)

            assert_equal 1, json[:data][:book_links_removed]
            assert_equal false, json[:meta][:dry_run]
            assert_equal true, json[:data][:category][:deleted]
            assert @sources.first.reload.deleted?
            assert_nil @sources.first.merged_into_id
            assert_equal 0, CategoryItem.where(category: @sources.first).count
          end

          test "deleting a protected category is 422, for a dry run too" do
            fiction = categories(:books_fiction_genre)

            destroy_category(fiction.id)
            assert_api_response_conform(status: 422, api: :admin)
            assert_match(/can't be deleted/, json[:detail])
            destroy_category(fiction.id, "?dry_run=true")
            assert_response :unprocessable_entity
            assert_not fiction.reload.deleted?
          end

          test "deleting an already deleted category is 422" do
            destroy_category(categories(:books_deleted_genre).id)
            assert_api_response_conform(status: 422, api: :admin)
          end

          test "delete 404s for unknown and other-site ids and 403s on a policy refusal" do
            destroy_category(999_999_999)
            assert_api_response_conform(status: 404, api: :admin)
            destroy_category(categories(:music_rock_genre).id)
            assert_response :not_found

            refuse_delete_of(@sources.first)
            destroy_category(@sources.first.id)
            assert_api_response_conform(status: 403, api: :admin)
            assert_not @sources.first.reload.deleted?
          end

          test "dry_run=false on delete really deletes" do
            destroy_category(@sources.first.id, "?dry_run=false")
            assert_equal false, json[:meta][:dry_run]
            assert @sources.first.reload.deleted?
          end

          test "a delete writes one log line" do
            Rails.logger.stubs(:info)
            Rails.logger.expects(:info).with(regexp_matches(/event=api_admin_category_delete outcome=succeeded .*category_id=#{@sources.first.id}/)).once

            destroy_category(@sources.first.id)
          end
        end
      end
    end
  end
end
