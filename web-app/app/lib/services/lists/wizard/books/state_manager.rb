# frozen_string_literal: true

module Services
  module Lists
    module Wizard
      module Books
        # Books list wizard steps (books list wizard spec, decision 7).
        class StateManager < Services::Lists::Wizard::StateManager
          STEPS = %w[paste parse match review import done].freeze

          def steps
            STEPS
          end
        end
      end
    end
  end
end
