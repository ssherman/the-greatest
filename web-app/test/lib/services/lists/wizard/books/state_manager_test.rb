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

          test "every update_step_status! stamps the entry for books; the base manager's does not" do
            list = ::Books::List.create!(name: "Stamp", status: :unapproved)

            list.wizard_manager.update_step_status!(step: "match", status: "running")
            assert list.reload.wizard_state.dig("steps", "match", "updated_at").present?
            assert_not list.wizard_manager.step_stalled?("match")

            Services::Lists::Wizard::StateManager.new(list).update_step_status!(step: "match", status: "running")
            assert_nil list.reload.wizard_state.dig("steps", "match", "updated_at")
          end
        end
      end
    end
  end
end
