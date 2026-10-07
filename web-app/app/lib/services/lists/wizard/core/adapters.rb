# frozen_string_literal: true

module Services
  module Lists
    module Wizard
      module Core
        # The one place a list type picks its wizard adapter. Music and games
        # add theirs when they move onto the core.
        module Adapters
          def self.for(list)
            case list.type
            when "Books::List" then ::Services::Lists::Wizard::Books::Adapter.new
            else raise ArgumentError, "no list wizard adapter for #{list.type}"
            end
          end
        end
      end
    end
  end
end
