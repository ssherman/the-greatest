# frozen_string_literal: true

module Api
  module V1
    module Admin
      # Strict id parsing for the admin endpoints, whose ids name records that
      # are edited or deleted.
      module StrictIds
        private

        # A JSON integer, or a string of plain decimal digits. Never Integer(str):
        # it honours radix prefixes ("010" is 8, "0x1A" is 26, "1_0" is 10), and
        # this id names a record that is about to be changed.
        def parse_id(value)
          id = value if value.is_a?(Integer)
          id = Integer(value, 10) if value.is_a?(String) && value.match?(/\A\d+\z/)

          (id && id >= 1) ? id : nil
        end
      end
    end
  end
end
