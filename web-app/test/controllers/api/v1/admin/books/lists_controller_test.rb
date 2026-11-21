require "test_helper"

module Api
  module V1
    module Admin
      module Books
        class ListsControllerTest < ActionDispatch::IntegrationTest
          READ = ApiTokenSecrets::ADMIN_READ

          setup do
            host! "dev-new.thegreatestbooks.org"
            @list = lists(:books_list)
          end

          def json = response.parsed_body.deep_symbolize_keys

          def ids = json[:data].map { |row| row[:id] }

          def search(params = {})
            get "/api/v1/admin/lists", params: {per_page: 100}.merge(params), headers: bearer(READ)
          end

          test "search returns only books lists" do
            search
            assert_api_response_conform(status: 200, api: :admin)

            assert_equal ::Books::List.pluck(:id).sort, ids.sort
            assert_not_includes ids, lists(:music_albums_list).id
          end

          test "a row carries its weight on the primary configuration and its last audit" do
            search
            row = json[:data].find { |r| r[:id] == @list.id }

            assert_equal 10, row[:weight]
            assert_equal list_audits(:books_verified_audit).id, row[:last_audit][:id]
            assert_equal "verified", row[:last_audit][:verdict]
            other = json[:data].find { |r| r[:id] == lists(:basic_list).id }
            assert_nil other[:weight]
            assert_nil other[:last_audit]
          end

          test "audit=verified returns the audited list and audit=not_audited excludes it" do
            search(audit: "verified")
            assert_equal [@list.id], ids

            search(audit: "not_audited")
            assert_not_includes ids, @list.id
            assert_includes ids, lists(:basic_list).id

            search(audit: "unverifiable")
            assert_equal [], ids
          end

          test "audit judges the latest finished audit, and in_progress finds open audits" do
            ListAudit.create!(list: @list, status: :finished, verdict: :unverifiable, started_at: 1.hour.ago, finished_at: 1.minute.ago, sources: [])
            search(audit: "verified")
            assert_not_includes ids, @list.id
            search(audit: "unverifiable")
            assert_equal [@list.id], ids

            search(audit: "in_progress")
            assert_equal [], ids
            ListAudit.create!(list: lists(:basic_list), status: :in_progress, started_at: Time.current, lease_expires_at: 1.hour.from_now, sources: [])
            search(audit: "in_progress")
            assert_equal [lists(:basic_list).id], ids
          end

          test "status and q filter, and sort orders" do
            search(status: "approved")
            assert_equal ::Books::List.approved.pluck(:id).sort, ids.sort

            search(q: @list.name)
            assert_includes ids, @list.id

            search(sort: "name")
            assert_equal ::Books::List.order(:name, :id).pluck(:id), ids

            search(sort: "id")
            assert_equal ::Books::List.order(:id).pluck(:id), ids

            search
            assert_equal @list.id, ids.first
          end

          test "a bad status, audit or sort is a 400" do
            %w[status audit sort].each do |name|
              search(name => "bogus")
              assert_response :bad_request
            end
          end

          test "search issues the same number of queries however many lists a page holds" do
            search
            before = count_queries { search }
            3.times { |i| ::Books::List.create!(name: "Extra #{i}", status: :approved) }

            assert_equal before, count_queries { search }
          end

          test "show carries the fields and audits" do
            get "/api/v1/admin/lists/#{@list.id}", headers: bearer(READ)
            assert_api_response_conform(status: 200, api: :admin)

            data = json[:data]
            assert_equal @list.id, data[:id]
            assert_equal [false, false], [data[:auto_generated], data[:has_raw_content]]
            assert_equal [list_audits(:books_verified_audit).id], data[:audits].map { |audit| audit[:id] }
            assert_nil data[:open_audit]
            assert_equal({}, data[:audits].first[:changes])
          end

          test "show renders an open audit with field_changes as changes" do
            ListAudit.create!(list: @list, user: users(:admin_user), status: :in_progress, started_at: Time.current,
              lease_expires_at: 1.hour.from_now, sources: [], field_changes: {"year_published" => {"from" => 1, "to" => 2}})
            get "/api/v1/admin/lists/#{@list.id}", headers: bearer(READ)
            assert_api_response_conform(status: 200, api: :admin)

            open_audit = json[:data][:open_audit]
            assert_equal "in_progress", open_audit[:status]
            assert_equal({year_published: {from: 1, to: 2}}, open_audit[:changes])
            assert_not_nil open_audit[:user_name]
          end

          test "show gives value_on_primary nil for a penalty with no application on the primary" do
            penalty = penalties(:static_penalty)
            ListPenalty.find_or_create_by!(list: @list, penalty: penalty)
            PenaltyApplication.where(penalty: penalty, ranking_configuration: ranking_configurations(:books_global)).delete_all
            get "/api/v1/admin/lists/#{@list.id}", headers: bearer(READ)
            assert_api_response_conform(status: 200, api: :admin)

            row = json[:data][:penalties].find { |p| p[:id] == penalty.id }
            assert_nil row[:value_on_primary]
            assert_equal "static", row[:kind]
          end

          test "show gives value_on_primary from the application on the primary" do
            penalty = penalties(:global_penalty)
            ListPenalty.find_or_create_by!(list: @list, penalty: penalty)
            PenaltyApplication.find_or_initialize_by(penalty: penalty, ranking_configuration: ranking_configurations(:books_global)).update!(value: 7)
            get "/api/v1/admin/lists/#{@list.id}", headers: bearer(READ)
            assert_api_response_conform(status: 200, api: :admin)

            assert_equal 7, json[:data][:penalties].find { |p| p[:id] == penalty.id }[:value_on_primary]
          end

          test "show of a list outside books is a 404" do
            get "/api/v1/admin/lists/#{lists(:music_albums_list).id}", headers: bearer(READ)

            assert_response :not_found
          end

          test "a member token is forbidden" do
            get "/api/v1/admin/lists", headers: bearer(ApiTokenSecrets::MEMBER)

            assert_response :forbidden
          end

          def count_queries
            count = 0
            ActiveRecord::Base.connection.clear_query_cache
            counter = ->(*, payload) { count += 1 unless %w[SCHEMA TRANSACTION].include?(payload[:name]) || payload[:cached] }
            ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
            count
          end
        end
      end
    end
  end
end
