# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Verification
      class CohortTest < ActiveSupport::TestCase
        test "legacy books created after the Goodreads imports feature are post_import" do
          assert_equal :pre_import, Cohort.for(16_571)
          assert_equal :post_import, Cohort.for(16_572)
          assert_equal :post_import, Cohort.for(249_999)
        end

        test "new-app books, above the reserved ceiling, are pre_import" do
          assert_equal :pre_import, Cohort.for(250_000)
        end
      end
    end
  end
end
