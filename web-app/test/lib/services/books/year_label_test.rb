# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    class YearLabelTest < ActiveSupport::TestCase
      test "a Common Era year is the number, a year before it is marked BCE, and nil stays nil" do
        assert_equal ["1828", "480 BCE", nil], [YearLabel.call(1828), YearLabel.call(-480), YearLabel.call(nil)]
      end

      test "lifespans mark BCE years too" do
        assert_equal ["480 BCE–406 BCE", "?–406 BCE", "1828–1910"],
          [Authors::AuthorProfile.lifespan(-480, -406), Authors::AuthorProfile.lifespan(nil, -406), Authors::AuthorProfile.lifespan(1828, 1910)]
      end
    end
  end
end
