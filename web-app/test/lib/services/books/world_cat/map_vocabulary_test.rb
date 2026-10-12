require "test_helper"

module Services
  module Books
    module WorldCat
      class MapVocabularyTest < ActiveSupport::TestCase
        class FakeTask
          cattr_accessor :calls, default: []

          def initialize(terms:, genres:, parent: nil)
            @terms = terms
            self.class.calls << terms.map(&:first)
          end

          def call
            verdicts = @terms.map do |term, _uses, _books|
              {term: term, verdict: (term == "Large type books") ? "drop" : "genre", genre: (term == "Large type books") ? nil : "Fiction",
               subject: nil, language: "en", reason: (term == "Large type books") ? "format" : nil}
            end
            ::Services::Ai::Result.new(success: true, data: {verdicts: verdicts})
          end
        end

        setup do
          FakeTask.calls = []
          @dir = Dir.mktmpdir
          @terms_path = File.join(@dir, "genre_terms.csv")
          File.write(@terms_path, "term,uses,books\nFiction,10,8\nRomans,5,4\nLarge type books,2,2\n")
          @out = File.join(@dir, "genre_map.yml")
        end

        teardown { FileUtils.remove_entry(@dir) }

        test "writes a verdict per term with counts, batched" do
          result = MapVocabulary.call(terms_path: @terms_path, out_path: @out, genres: ["Fiction"], task_class: FakeTask, batch_size: 2)

          assert result.success?
          assert_equal({mapped: 3, skipped_existing: 0, batches: 2}, result.data)
          assert_equal [["Fiction", "Romans"], ["Large type books"]], FakeTask.calls
          yaml = YAML.safe_load_file(@out)
          assert_equal 1, yaml["version"]
          assert_equal ["Fiction"], yaml["genres"]
          assert_equal({"verdict" => "genre", "genre" => "Fiction", "language" => "en", "uses" => 5, "books" => 4}, yaml["terms"]["Romans"])
          assert_equal({"verdict" => "drop", "reason" => "format", "language" => "en", "uses" => 2, "books" => 2}, yaml["terms"]["Large type books"])
        end

        test "an existing file is extended, not re-asked" do
          File.write(@out, {"version" => 1, "genres" => ["Fiction"], "terms" => {"Fiction" => {"verdict" => "genre", "genre" => "Fiction", "uses" => 10, "books" => 8}}}.to_yaml)
          result = MapVocabulary.call(terms_path: @terms_path, out_path: @out, genres: ["Fiction"], task_class: FakeTask)
          assert_equal({mapped: 2, skipped_existing: 1, batches: 1}, result.data)
          assert_equal [["Romans", "Large type books"]], FakeTask.calls
          assert_equal 3, YAML.safe_load_file(@out)["terms"].size
        end

        test "a failed batch stops and reports, keeping what was written" do
          failing = Class.new do
            define_method(:initialize) { |**| }
            define_method(:call) { ::Services::Ai::Result.new(success: false, error: "quota") }
          end
          result = MapVocabulary.call(terms_path: @terms_path, out_path: @out, genres: ["Fiction"], task_class: failing)
          assert_not result.success?
          assert_match(/quota/, result.errors.first)
        end
      end
    end
  end
end
