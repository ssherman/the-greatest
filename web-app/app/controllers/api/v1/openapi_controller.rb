# frozen_string_literal: true

module Api
  module V1
    # GET /api/v1/openapi.json -- public, no token, cacheable for an hour.
    # Not a BaseController subclass on purpose: that base authenticates.
    class OpenapiController < ActionController::API
      include CurrentDomain

      def show
        expires_in 1.hour, public: true
        render json: ::Api::OpenapiDocument.for_host(::Api::Host.base_url, domain: Current.domain)
      end
    end
  end
end
