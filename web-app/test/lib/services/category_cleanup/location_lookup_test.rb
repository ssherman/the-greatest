require "test_helper"

module Services
  module CategoryCleanup
    class LocationLookupTest < ActiveSupport::TestCase
      test "finds live locations by name or alternative name, ignoring case and punctuation" do
        kolkata = ::Books::Category.create!(name: "Kolkata", category_type: :location, alternative_names: ["Calcutta"])
        ::Books::Category.create!(name: "Ghost Town", category_type: :location, deleted: true)
        ::Books::Category.create!(name: "Kolkata Studies", category_type: :subject)
        lookup = LocationLookup.new

        assert_equal kolkata.id, lookup.find("KOLKATA")
        assert_equal kolkata.id, lookup.find("calcutta")
        assert_nil lookup.find("Ghost Town")
        assert_nil lookup.find("Kolkata Studies")
      end

      test "register adds a category created after the lookup was built" do
        lookup = LocationLookup.new
        europe = ::Books::Category.create!(name: "Europe", category_type: :location)
        lookup.register(europe)

        assert_equal europe.id, lookup.find("Europe")
      end

      test "never indexes a letterless name and find returns nil for one" do
        junk = ::Books::Category.create!(name: "(?)", category_type: :location, alternative_names: ["--"])
        lookup = LocationLookup.new
        lookup.register(junk)

        assert_nil lookup.find("(?)")
        assert_nil lookup.find("--")
        assert_nil lookup.find("!!!")
      end
    end
  end
end
