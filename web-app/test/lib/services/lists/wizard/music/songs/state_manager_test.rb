# frozen_string_literal: true

require "test_helper"

module Services
  module Lists
    module Wizard
      module Music
        module Songs
          class StateManagerTest < ActiveSupport::TestCase
            setup do
              @list = lists(:music_songs_list)
              @list.update!(wizard_state: nil)
            end

            test "#steps returns song wizard steps" do
              manager = StateManager.new(@list)
              expected = %w[source parse enrich validate review import complete]
              assert_equal expected, manager.steps
            end

            test "STEPS constant is frozen" do
              assert StateManager::STEPS.frozen?
            end

            test "inherits from base StateManager" do
              manager = StateManager.new(@list)
              assert_kind_of Services::Lists::Wizard::StateManager, manager
            end

            test "factory returns Songs::StateManager for Music::Songs::List" do
              manager = Services::Lists::Wizard::StateManager.for(@list)
              assert_instance_of StateManager, manager
            end
          end
        end
      end
    end
  end
end
