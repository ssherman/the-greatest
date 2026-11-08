# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Origin
      class CountryLanguagesTest < ActiveSupport::TestCase
        test "a language of the country" do
          assert CountryLanguages.include?("French", "french")
          assert CountryLanguages.include?("greek", "Ancient greek")
        end

        test "a language that is not the country's" do
          refute CountryLanguages.include?("French", "English")
        end

        test "an unknown country or a nil is false" do
          refute CountryLanguages.include?("Atlantean", "English")
          refute CountryLanguages.include?("French", nil)
          refute CountryLanguages.include?(nil, "French")
        end
      end
    end
  end
end
