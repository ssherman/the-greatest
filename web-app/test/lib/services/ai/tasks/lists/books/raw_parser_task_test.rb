# frozen_string_literal: true

require "test_helper"

module Services
  module Ai
    module Tasks
      module Lists
        module Books
          class RawParserTaskTest < ActiveSupport::TestCase
            test "the response schema requires a subtitle on every book" do
              schema = RawParserTask::Book.to_json_schema

              assert_includes schema[:properties].keys.map(&:to_s), "subtitle"
              assert_includes Array(schema[:required]).map(&:to_s), "subtitle"
            end
          end
        end
      end
    end
  end
end
