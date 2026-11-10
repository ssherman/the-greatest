# frozen_string_literal: true

module Api
  module V1
    module Admin
      module Books
        # Root-anchored superclass: inside Api::V1::Admin::Books a bare
        # BaseController is this class itself. Every model and search reference
        # in this namespace is root-anchored too (::Books::Book): a bare Books::
        # resolves to Api::V1::Admin::Books:: and raises NameError.
        class BaseController < ::Api::V1::BaseController
          require_scope "books:admin:read"

          # The most hits a search pages through. Admin search is a lookup, not
          # an export: a query matching more than this should be refined.
          SEARCH_LIMIT = 1000

          before_action :set_acting_user

          private

          # Lets mergers record who resolved a duplicate pair (see Current).
          def set_acting_user
            Current.acting_user = current_principal.user
            Current.acting_via = "api"
          end

          # The search text, or nil after rendering the 400 -- so a blank query
          # is never an empty 200 and never a page of the whole table.
          def required_query
            query = params[:q].to_s.strip
            return query if query.present?

            render_problem(::Api::Problem.new(:invalid_parameter, detail: "q is required"))
            nil
          end

          # The search hits' ids, in match order.
          def hit_ids(hits) = hits.map { |hit| hit[:id].to_i }
        end
      end
    end
  end
end
