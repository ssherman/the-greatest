# frozen_string_literal: true

require "test_helper"

class Viaf::NormalizerTest < ActiveSupport::TestCase
  test "strips the ns1 prefix used by cluster fetches" do
    assert_equal({"viafID" => 1}, Viaf::Normalizer.call({"ns1:viafID" => 1}))
  end

  test "strips incrementing prefixes used by search results" do
    input = {"ns2:VIAFCluster" => {"ns3:viafID" => 1}}

    assert_equal({"VIAFCluster" => {"viafID" => 1}}, Viaf::Normalizer.call(input))
  end

  # viapy normalizes with /^ns\d+:/ which silently fails here and yields a nil
  # lookup rather than an error. BriefVIAF really does use a "v:" prefix.
  test "strips a non-numeric prefix such as BriefVIAF's v:" do
    assert_equal({"VIAFCluster" => {}}, Viaf::Normalizer.call({"v:VIAFCluster" => {}}))
  end

  test "preserves xmlns declarations" do
    input = {"xmlns:foaf" => "http://xmlns.com/foaf/0.1/", "ns1:viafID" => 1}

    assert_equal(
      {"xmlns:foaf" => "http://xmlns.com/foaf/0.1/", "viafID" => 1},
      Viaf::Normalizer.call(input)
    )
  end

  test "recurses through arrays" do
    input = {"ns1:sources" => [{"ns1:s" => "LC"}, {"ns1:s" => "BNF"}]}

    assert_equal({"sources" => [{"s" => "LC"}, {"s" => "BNF"}]}, Viaf::Normalizer.call(input))
  end

  test "leaves keys without a prefix alone" do
    assert_equal({"content" => 5}, Viaf::Normalizer.call({"content" => 5}))
  end

  test "leaves scalars alone" do
    assert_equal 5, Viaf::Normalizer.call(5)
    assert_nil Viaf::Normalizer.call(nil)
  end

  test "array wraps a bare value" do
    assert_equal ["LC"], Viaf::Normalizer.array("LC")
  end

  test "array passes an array through" do
    assert_equal ["LC", "BNF"], Viaf::Normalizer.array(["LC", "BNF"])
  end

  test "array turns nil into an empty array" do
    assert_equal [], Viaf::Normalizer.array(nil)
  end
end
