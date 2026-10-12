require "test_helper"

module Services
  module CategoryCleanup
    class NameNormalizerTest < ActiveSupport::TestCase
      # Real names from the dev database, 2026-10-11.
      TARGETS = {
        "Japan (" => "Japan",
        "United Kingdom (" => "United Kingdom",
        "Podgorica (Montenegro" => "Podgorica",
        "61)" => :delete,
        "2014)" => :delete,
        "(" => :delete,
        "Self‑discovery" => "Self-discovery",
        "  Massachusetts" => "Massachusetts",
        "England," => "England",
        "secrets" => "Secrets",
        "isolation and loneliness" => "Isolation and Loneliness",
        "Death & Grief" => "Death and Grief",
        "Washington D.C." => "Washington D.C.",
        "Kolkata (Calcutta)" => "Kolkata (Calcutta)",
        "9/11" => "9/11",
        "iPhone culture" => "iPhone Culture"
      }.freeze

      TARGETS.each do |input, expected|
        test "target_name(#{input.inspect}) is #{expected.inspect}" do
          assert_equal expected, NameNormalizer.target_name(input)
        end
      end

      test "twins share a key across case and punctuation" do
        assert_equal NameNormalizer.twin_key("Washington D.C."), NameNormalizer.twin_key("Washington, D.C.")
        assert_equal NameNormalizer.twin_key("Decision-making"), NameNormalizer.twin_key("Decision making")
        assert_equal NameNormalizer.twin_key("Women's Studies"), NameNormalizer.twin_key("Womens Studies")
        refute_equal NameNormalizer.twin_key("Georgia"), NameNormalizer.twin_key("Georgia (U.S. state)")
      end

      test "clean maps typographic dashes and quotes to ASCII" do
        assert_equal "Women's Studies", NameNormalizer.clean("Women’s Studies")
        assert_equal "Self-discovery", NameNormalizer.clean("Self‑discovery")
      end
    end
  end
end
