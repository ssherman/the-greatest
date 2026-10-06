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

          # Books stamps every step write, whichever path makes it (the match
          # and import jobs call this directly), so a live step never loses the
          # stamp #step_stalled? reads. The base manager stays unstamped.
          def update_step_status!(step:, status:, progress: nil, error: nil, metadata: {}, stamp: true)
            super
          end
        end
      end
    end
  end
end
