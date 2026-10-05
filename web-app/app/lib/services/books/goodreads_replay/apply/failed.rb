# frozen_string_literal: true

module Services
  module Books
    module GoodreadsReplay
      module Apply
        # A verdict that could not be applied; ApplyVerdicts records the message on it.
        class Failed < StandardError; end
      end
    end
  end
end
