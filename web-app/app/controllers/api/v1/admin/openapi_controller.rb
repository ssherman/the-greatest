# frozen_string_literal: true

module Api
  module V1
    module Admin
      # GET /api/v1/admin/openapi.json -- the admin contract, for tokens holding
      # books:admin:read. A BaseController subclass (unlike the public document),
      # so it authenticates, is rate limited and is never cached.
      class OpenapiController < ::Api::V1::BaseController
        require_scope "books:admin:read"

        def show
          render json: ::Api::OpenapiDocument.for_host(::Api::Host.base_url, domain: Current.domain, document: :admin)
        end
      end
    end
  end
end
