# frozen_string_literal: true

require "test_helper"

module Wikipedia
  class InfoboxTest < ActiveSupport::TestCase
    test "reads the wanted fields and cleans their markup" do
      wikitext = <<~WIKI
        {{Infobox book
        | name = Lolita
        | country = United States
        | language = English
        | genre = [[Novel]]<ref>x</ref>
        | set_in = {{plainlist|* [[New England]]
        * [[Ramsdale]]}}
        }}
      WIKI

      assert_equal({"country" => "United States", "language" => "English", "genre" => "Novel",
        "set_in" => "New England, Ramsdale"}, Infobox.fields(wikitext))
    end

    test "matches parameter names case-insensitively with spaces for underscores" do
      wikitext = "{{infobox novel\n| Set in = [[Paris|Paris, France]]<br />London\n| Genre = {{hlist|[[Crime]]|[[Thriller|thriller]]}}\n}}"

      assert_equal({"set_in" => "Paris, France, London", "genre" => "Crime, thriller"}, Infobox.fields(wikitext))
    end

    test "drops other templates, self-closing refs, and ignores text without an infobox" do
      assert_equal({"country" => "France"}, Infobox.fields("{{Infobox book\n| country = France{{efn|note}}<ref name=a />\n}}"))
      assert_equal({}, Infobox.fields("Just text"))
      assert_equal({}, Infobox.fields(nil))
    end
  end
end
