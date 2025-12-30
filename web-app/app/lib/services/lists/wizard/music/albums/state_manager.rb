# frozen_string_literal: true

module Services
  module Lists
    module Wizard
      module Music
        module Albums
          # StateManager for Music::Albums::List wizard.
          # Defines the specific steps for the album import wizard.
          #
          # == Steps
          #
          # 1. source - Select import source (custom HTML or MusicBrainz series)
          # 2. parse - Parse HTML to extract album items
          # 3. enrich - Enrich items with MusicBrainz/OpenSearch data
          # 4. validate - AI validation of matches
          # 5. review - Manual verification of items
          # 6. import - Create album records
          # 7. complete - Summary display
          #
          class StateManager < Services::Lists::Wizard::StateManager
            STEPS = %w[source parse enrich validate review import complete].freeze

            # Returns the ordered array of step names for the album wizard.
            #
            # @return [Array<String>] step names in order
            def steps
              STEPS
            end
          end
        end
      end
    end
  end
end
