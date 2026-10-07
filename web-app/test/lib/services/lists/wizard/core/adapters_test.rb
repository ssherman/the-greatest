# frozen_string_literal: true

require "test_helper"

module Services
  module Lists
    module Wizard
      module Core
        class AdaptersTest < ActiveSupport::TestCase
          test "a books list gets the books adapter" do
            assert_instance_of ::Services::Lists::Wizard::Books::Adapter, Adapters.for(lists(:books_list))
          end

          test "a list type with no adapter is refused" do
            assert_raises(ArgumentError) { Adapters.for(lists(:games_list)) }
          end
        end
      end
    end
  end
end
