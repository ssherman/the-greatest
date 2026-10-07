# frozen_string_literal: true

require "test_helper"

module Services
  module Ai
    module Tasks
      module Lists
        module Games
          class ListItemsValidatorTaskTest < ActiveSupport::TestCase
            include ValidatorResponseStub

            setup do
              @list = lists(:games_list)
              @list.list_items.destroy_all
              @manual = @list.list_items.create!(position: 1, verified: true,
                metadata: {"title" => "Hades", "igdb_id" => 113112, "igdb_name" => "Hades", "manual_igdb_link" => true})
              @plain = @list.list_items.create!(position: 2, verified: false,
                metadata: {"title" => "Zelda", "developers" => ["Nintendo"], "igdb_id" => 1, "igdb_name" => "Zelda II"})
            end

            test "a hand-linked row handed to the validator is left out of the prompt and untouched" do
              stub_validator_response(invalid: [1])

              result = ListItemsValidatorTask.new(parent: @list, items: [@manual, @plain]).call

              assert result.success?
              assert @manual.reload.verified?
              refute @manual.metadata.key?("ai_match_invalid")
              assert_equal true, @plain.reload.metadata["ai_match_invalid"]
            end

            test "without provided items a hand-linked row is still skipped" do
              # Unverified, so the task's own unverified scope would pick it up.
              # Were it validated it would be marked valid and verified.
              @manual.update!(verified: false)
              stub_validator_response(invalid: [1])

              ListItemsValidatorTask.new(parent: @list).call

              refute @manual.reload.verified?
              refute @manual.metadata.key?("ai_match_invalid")
              assert_equal true, @plain.reload.metadata["ai_match_invalid"]
            end
          end
        end
      end
    end
  end
end
