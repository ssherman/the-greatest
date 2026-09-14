# frozen_string_literal: true

module Api
  module V1
    module Books
      # Root-anchored superclass: inside Api::V1::Books a bare BaseController
      # is this class itself.
      class BaseController < ::Api::V1::BaseController
        require_scope "books:read"
      end
    end
  end
end
