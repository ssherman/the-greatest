# frozen_string_literal: true

require "test_helper"

module Services
  module Text
    class NameFolderTest < ActiveSupport::TestCase
      test "drops case and diacritics" do
        assert_equal "gabriel garcia marquez", NameFolder.call("Gabriel García Márquez")
      end

      test "transliterates the letters NFD leaves whole" do
        {
          "Stanisław Lem" => "stanislaw lem",
          "Søren Kierkegaard" => "soren kierkegaard",
          "Ærø" => "aero",
          "Œuvres" => "oeuvres",
          "Straße" => "strasse",
          "Þórbergur Þórðarson" => "thorbergur thordarson",
          "Đorđe" => "dorde",
          "Işık" => "isik"
        }.each { |text, folded| assert_equal folded, NameFolder.call(text), text }
      end

      test "nil folds to an empty string" do
        assert_equal "", NameFolder.call(nil)
      end
    end
  end
end
