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

    test "strips html comments and refs before splitting parameters" do
      wikitext = "{{Infobox book\n| genre = <!-- See WP:NOVELS -->\n| country = United States<!-- first\npublication -->\n| language = USA<ref>Smith | Jones = x</ref>\n}}"

      assert_equal({"country" => "United States", "language" => "USA"}, Infobox.fields(wikitext))
    end

    test "nested templates leave no residue" do
      fields = Infobox.fields("{{Infobox book\n| country = France{{efn|Published {{small|first}} in Paris}}\n| set_in = {{plainlist|\n* {{lang|fr|Paris}}\n* London\n}}\n}}")

      assert_equal "France", fields["country"]
      assert_equal "London", fields["set_in"]
      fields.each_value { |v| assert_no_match(/\{\{|\}\}/, v) }
    end

    test "strips emphasis and decodes entities" do
      fields = Infobox.fields("{{Infobox book\n| genre = '''Gothic''' &amp; ''horror''&nbsp;novel\n}}")

      assert_equal "Gothic & horror novel", fields["genre"]
    end

    test "drops other templates,self-closing refs, and ignores text without an infobox" do
      assert_equal({"country" => "France"}, Infobox.fields("{{Infobox book\n| country = France{{efn|note}}<ref name=a />\n}}"))
      assert_equal({}, Infobox.fields("Just text"))
      assert_equal({}, Infobox.fields(nil))
    end
  end
end
