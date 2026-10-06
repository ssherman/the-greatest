# frozen_string_literal: true

require "test_helper"

module Services
  module Lists
    module Wizard
      module Books
        class StateManagerTest < ActiveSupport::TestCase
          test "names the books wizard's six steps, Paste first" do
            manager = StateManager.new(lists(:books_list))

            assert_equal %w[paste parse match review import done], manager.steps
            assert_equal "paste", manager.current_step_name
          end
        end
      end
    end
  end
end
