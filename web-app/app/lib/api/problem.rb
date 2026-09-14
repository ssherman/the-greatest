# frozen_string_literal: true

# RFC 9457 Problem Details, one per error code the API can answer with. The
# `code` member is the stable machine-readable string clients switch on; `type`
# points at that code's section on this host's /developers page (which ships
# in increment 3 -- a type URI is an identifier first and a link second).
#
# 500s are deliberately not here: an unexpected exception is a bug, and the
# base controller lets it reach Rails' handler (a generic JSON 500) rather than
# dressing it up.
module Api
  class Problem
    CONTENT_TYPE = "application/problem+json"

    DEFINITIONS = {
      unauthenticated: [401, "Authentication required"],
      invalid_token: [401, "Invalid token"],
      membership_required: [403, "Membership required"],
      insufficient_scope: [403, "Insufficient scope"],
      not_found: [404, "Not found"],
      invalid_parameter: [400, "Invalid parameter"],
      rate_limited: [429, "Rate limit exceeded"]
    }.freeze

    CODES = DEFINITIONS.keys.freeze

    attr_reader :code, :status, :title, :detail

    def initialize(code, detail: nil)
      @code = code.to_sym
      @status, @title = DEFINITIONS.fetch(@code)
      @detail = detail
    end

    def to_h
      {
        type: "#{Host.base_url}/developers#errors-#{code}",
        title: title,
        status: status,
        code: code.to_s,
        detail: detail
      }.compact
    end
  end
end
