# frozen_string_literal: true

# The membership gate is a cap, not a redirect (spec D7): a non-member gets a
# file, just a shorter one. nil means "no limit".
module CsvExports
  module Limits
    PREVIEW_ROWS = 500

    def self.limit_for(user)
      user&.member? ? nil : PREVIEW_ROWS
    end
  end
end
