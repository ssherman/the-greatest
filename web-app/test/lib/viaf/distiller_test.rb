# frozen_string_literal: true

require "test_helper"

class Viaf::DistillerTest < ActiveSupport::TestCase
  # Shapes below are copied from real responses observed on 2026-08-30.
  def cluster(overrides = {})
    {
      "ns1:VIAFCluster" => {
        "ns1:viafID" => 96987389,
        "ns1:nameType" => "Personal",
        "ns1:birthDate" => "1828-09-09",
        "ns1:deathDate" => "1910-11-20",
        "ns1:dateType" => "lived",
        "ns1:fixed" => {"ns1:gender" => "b"},
        "ns1:sources" => {
          "ns1:source" => [
            {"ns1:nsid" => "n  79068416", "ns1:content" => "LC|n  79068416"},
            {"ns1:nsid" => "Q7243", "ns1:content" => "WKP|Q7243"},
            {"ns1:nsid" => 56654, "ns1:content" => "PTBNP|56654"}
          ]
        },
        "ns1:mainHeadings" => {
          "ns1:mainHeadingEl" => [{
            "ns1:sources" => {"ns1:s" => "LC"},
            "ns1:datafield" => {
              "tag" => 100,
              "ns1:subfield" => [
                {"code" => "a", "content" => "Tolstoy, Leo,"},
                {"code" => "d", "content" => "1828-1910"}
              ]
            }
          }]
        },
        "ns1:x400s" => {
          "ns1:x400" => [{
            "ns1:datafield" => {
              "tag" => 400,
              "ns1:subfield" => [{"code" => "a", "content" => "Tolstoi, Lev Nikolaevich"}]
            }
          }]
        },
        "ns1:nationalityOfEntity" => {
          "ns1:data" => {"ns1:sources" => {"ns1:s" => ["LC", "BNF"]}, "ns1:text" => "RU"}
        },
        "ns1:languageOfEntity" => {"ns1:data" => {"ns1:text" => "rus"}},
        "ns1:occupation" => {"ns1:data" => [{"ns1:text" => "authors"}]},
        "ns1:fieldOfActivity" => {"ns1:data" => [{"ns1:text" => "literature"}]}
      }
    }.deep_merge(overrides)
  end

  def distill(overrides = {}, requested_id: "96987389")
    Viaf::Distiller.call(cluster(overrides), requested_id: requested_id)
  end

  test "extracts the scalar fields" do
    result = distill

    assert_equal "Personal", result["name_type"]
    assert_equal "1828-09-09", result["birth_date"]
    assert_equal "1910-11-20", result["death_date"]
    assert_equal "lived", result["date_type"]
    assert_equal "b", result["gender"]
  end

  # VIAF has been seen emitting viafID in scientific notation, which Ruby parses
  # as a Float and coerces back to the WRONG integer. Always carry the requested id.
  test "uses the requested id rather than the echoed one" do
    result = distill({"ns1:VIAFCluster" => {"ns1:viafID" => 2.71711845065478e+19}},
      requested_id: "27171184506547771093")

    assert_equal "27171184506547771093", result["viaf_id"]
  end

  test "viaf_id is always a string" do
    assert_instance_of String, distill["viaf_id"]
  end

  test "parses source ids from content, splitting on the pipe" do
    result = distill

    assert_equal "Q7243", result["source_ids"]["WKP"]
    assert_equal "56654", result["source_ids"]["PTBNP"]
  end

  # LC arrives space-padded as "n  79068416" but AutoSuggest returns "n79068416"
  # for the same record. Squeezing instead of stripping writes two values.
  test "strips all whitespace from identifier values" do
    assert_equal "n79068416", distill["source_ids"]["LC"]
  end

  # nsid and content can disagree; content is authoritative.
  test "prefers content over a disagreeing nsid" do
    result = distill({"ns1:VIAFCluster" => {"ns1:sources" => {"ns1:source" => [
      {"ns1:nsid" => "LNB:V*35849;=BP", "ns1:content" => "LIH|LNB:V-35849;=BP"}
    ]}}})

    assert_equal "LNB:V-35849;=BP", result["source_ids"]["LIH"]
  end

  test "handles a single source that is not wrapped in an array" do
    result = distill({"ns1:VIAFCluster" => {"ns1:sources" => {
      "ns1:source" => {"ns1:content" => "LC|n123"}
    }}})

    assert_equal "n123", result["source_ids"]["LC"]
  end

  test "keeps the first source id when an agency code repeats" do
    result = distill({"ns1:VIAFCluster" => {"ns1:sources" => {"ns1:source" => [
      {"ns1:content" => "BNF|11898689"},
      {"ns1:content" => "BNF|22222222"}
    ]}}})

    assert_equal "11898689", result["source_ids"]["BNF"]
  end

  test "skips source entries with unparseable content" do
    result = distill({"ns1:VIAFCluster" => {"ns1:sources" => {"ns1:source" => [
      {"ns1:content" => "NOPIPE"},
      {"ns1:content" => 12345},
      {"ns1:content" => "WKP|Q7243"}
    ]}}})

    assert_equal({"WKP" => "Q7243"}, result["source_ids"])
  end

  test "handles a source entry that is a bare content string, not a hash" do
    result = distill({"ns1:VIAFCluster" => {"ns1:sources" => {"ns1:source" => "LC|n123"}}})

    assert_equal "n123", result["source_ids"]["LC"]
  end

  test "keeps main headings with their contributing source" do
    assert_equal [{"source" => "LC", "name" => "Tolstoy, Leo"}], distill["main_headings"]
  end

  # MARC21 tag 100 and UNIMARC tag 200 assign different meanings to the same
  # subfield codes, and some agencies use integer codes. Naive joining yields
  # "eng ba Austen J. 1775-1817 Jane".
  test "selects only name subfields and ignores integer codes" do
    result = distill({"ns1:VIAFCluster" => {"ns1:mainHeadings" => {"ns1:mainHeadingEl" => [{
      "ns1:sources" => {"ns1:s" => "NLR"},
      "ns1:datafield" => {"tag" => 200, "ns1:subfield" => [
        {"code" => 8, "content" => "eng"},
        {"code" => 7, "content" => "ba"},
        {"code" => "a", "content" => "Austen"},
        {"code" => "b", "content" => "J."},
        {"code" => "f", "content" => "1775-1817"},
        {"code" => "g", "content" => "Jane"}
      ]}
    }]}}})

    assert_equal [{"source" => "NLR", "name" => "Austen J."}], result["main_headings"]
  end

  test "takes the first source when a heading lists several" do
    result = distill({"ns1:VIAFCluster" => {"ns1:mainHeadings" => {"ns1:mainHeadingEl" => [{
      "ns1:sources" => {"ns1:s" => ["DNB", "SZ"]},
      "ns1:datafield" => {"tag" => 100, "ns1:subfield" => [{"code" => "a", "content" => "Tolstoi"}]}
    }]}}})

    assert_equal "DNB", result["main_headings"].first["source"]
  end

  test "skips a main heading whose subfields yield no name" do
    result = distill({"ns1:VIAFCluster" => {"ns1:mainHeadings" => {"ns1:mainHeadingEl" => [
      {
        "ns1:sources" => {"ns1:s" => "LC"},
        "ns1:datafield" => {"ns1:subfield" => [{"code" => "d", "content" => "1828-1910"}]}
      },
      {
        "ns1:sources" => {"ns1:s" => "WKP"},
        "ns1:datafield" => {"ns1:subfield" => [{"code" => "a", "content" => "Tolstoy"}]}
      }
    ]}}})

    assert_equal [{"source" => "WKP", "name" => "Tolstoy"}], result["main_headings"]
  end

  test "ignores a subfield entry that is not a hash" do
    result = distill({"ns1:VIAFCluster" => {"ns1:mainHeadings" => {"ns1:mainHeadingEl" => [{
      "ns1:sources" => {"ns1:s" => "LC"},
      "ns1:datafield" => {"ns1:subfield" => ["not-a-hash", {"code" => "a", "content" => "Tolstoy"}]}
    }]}}})

    assert_equal [{"source" => "LC", "name" => "Tolstoy"}], result["main_headings"]
  end

  # MARC subfield content routinely carries leading/internal double spaces;
  # squish must not be dropped or these leak straight into the persisted name.
  test "squishes leading and internal whitespace out of subfield content" do
    result = distill({"ns1:VIAFCluster" => {"ns1:mainHeadings" => {"ns1:mainHeadingEl" => [{
      "ns1:sources" => {"ns1:s" => "LC"},
      "ns1:datafield" => {"ns1:subfield" => [{"code" => "a", "content" => "  Austen,   Jane"}]}
    }]}}})

    assert_equal [{"source" => "LC", "name" => "Austen, Jane"}], result["main_headings"]
  end

  test "collects deduplicated alternate names from x400s" do
    result = distill({"ns1:VIAFCluster" => {"ns1:x400s" => {"ns1:x400" => [
      {"ns1:datafield" => {"ns1:subfield" => [{"code" => "a", "content" => "Tolstoi"}]}},
      {"ns1:datafield" => {"ns1:subfield" => [{"code" => "a", "content" => "Tolstoi"}]}},
      {"ns1:datafield" => {"ns1:subfield" => [{"code" => "a", "content" => "تولستوي"}]}}
    ]}}})

    assert_equal ["Tolstoi", "تولستوي"], result["names"].sort
  end

  test "collects text values, coercing a lone data hash into an array" do
    result = distill

    assert_equal ["RU"], result["nationality"]
    assert_equal ["rus"], result["language"]
    assert_equal ["authors"], result["occupation"]
    assert_equal ["literature"], result["field_of_activity"]
  end

  test "deduplicates text values within a field" do
    result = distill({"ns1:VIAFCluster" => {"ns1:occupation" => {"ns1:data" => [
      {"ns1:text" => "authors"},
      {"ns1:text" => "authors"}
    ]}}})

    assert_equal ["authors"], result["occupation"]
  end

  test "returns empty collections when fields are absent" do
    minimal = {"ns1:VIAFCluster" => {"ns1:viafID" => 1, "ns1:nameType" => "Personal"}}
    result = Viaf::Distiller.call(minimal, requested_id: "1")

    assert_nil result["birth_date"]
    assert_nil result["gender"]
    assert_empty result["source_ids"]
    assert_empty result["names"]
    assert_empty result["nationality"]
  end

  test "raises AbandonedRecordError for a withdrawn cluster" do
    assert_raises(Viaf::Exceptions::AbandonedRecordError) do
      Viaf::Distiller.call({"ns1:abandoned_viaf_record" => "true"}, requested_id: "1")
    end
  end

  test "raises AbandonedRecordError for a scavenged cluster" do
    assert_raises(Viaf::Exceptions::AbandonedRecordError) do
      Viaf::Distiller.call({"ns1:scavenged" => "true"}, requested_id: "1")
    end
  end

  # redirect/directto never appear at the top level: redirect is a child of
  # VIAFCluster, and directto is a child of redirect. A top-level-only check
  # silently distills a withdrawn record as if it were a real person.
  test "raises AbandonedRecordError for a redirect/directto nested under VIAFCluster" do
    assert_raises(Viaf::Exceptions::AbandonedRecordError) do
      Viaf::Distiller.call(
        {"ns1:VIAFCluster" => {"ns1:redirect" => {"ns1:directto" => "96987389"}}},
        requested_id: "1"
      )
    end
  end

  test "raises ParseError when no cluster is present" do
    assert_raises(Viaf::Exceptions::ParseError) do
      Viaf::Distiller.call({"something" => "else"}, requested_id: "1")
    end
  end

  # `.dig` is used through every intermediate node while Normalizer.array only
  # guards the leaves. If sources arrives as an Array (Hash expected), dig
  # raises a bare TypeError; this must surface as a Viaf::Exceptions::Error so
  # Task 10's rescue can catch it.
  test "raises ParseError instead of a bare TypeError when a hash is unexpectedly an array" do
    assert_raises(Viaf::Exceptions::ParseError) do
      Viaf::Distiller.call(
        {"ns1:VIAFCluster" => {"ns1:sources" => [{"ns1:source" => {"ns1:content" => "LC|n1"}}]}},
        requested_id: "1"
      )
    end
  end
end
