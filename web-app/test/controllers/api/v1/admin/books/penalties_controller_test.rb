require "test_helper"

module Api
  module V1
    module Admin
      module Books
        class PenaltiesControllerTest < ActionDispatch::IntegrationTest
          READ = ApiTokenSecrets::ADMIN_READ

          setup { host! "dev-new.thegreatestbooks.org" }

          def json = response.parsed_body.deep_symbolize_keys

          test "lists the books catalogue only, with the driving field of a dynamic penalty" do
            get "/api/v1/admin/penalties", headers: bearer(READ)
            assert_api_response_conform(status: 200, api: :admin)

            ids = json[:data].map { |row| row[:id] }
            assert_equal ::Penalty.where(type: %w[Books::Penalty Global::Penalty], user_id: nil).pluck(:id).sort, ids.sort
            assert_not_includes ids, penalties(:movies_penalty).id
            assert_not_includes ids, penalties(:music_penalty).id
            assert_not_includes ids, penalties(:user_books_penalty).id

            dynamic = json[:data].find { |row| row[:id] == penalties(:dynamic_penalty).id }
            assert_equal ["dynamic", "number_of_voters", "number_of_voters"], [dynamic[:kind], dynamic[:dynamic_type], dynamic[:driving_field]]
            static = json[:data].find { |row| row[:id] == penalties(:static_penalty).id }
            assert_equal "static", static[:kind]
            assert_nil static[:driving_field]
          end

          test "value_on_primary and books_list_count are read from the data" do
            penalty = penalties(:global_penalty)
            ListPenalty.find_or_create_by!(list: lists(:books_list), penalty: penalty)
            PenaltyApplication.find_or_initialize_by(penalty: penalty, ranking_configuration: ranking_configurations(:books_global)).update!(value: 7)
            get "/api/v1/admin/penalties", headers: bearer(READ)
            assert_api_response_conform(status: 200, api: :admin)

            row = json[:data].find { |r| r[:id] == penalty.id }
            assert_equal [7, 1], [row[:value_on_primary], row[:books_list_count]]
          end

          test "rows are ordered by category then name" do
            get "/api/v1/admin/penalties", headers: bearer(READ)

            keys = json[:data].map { |row| [row[:category] ? ::Penalty.categories[row[:category]] : 99, row[:name]] }
            assert_equal keys.sort, keys
          end

          test "a member token is forbidden" do
            get "/api/v1/admin/penalties", headers: bearer(ApiTokenSecrets::MEMBER)

            assert_response :forbidden
          end
        end
      end
    end
  end
end
