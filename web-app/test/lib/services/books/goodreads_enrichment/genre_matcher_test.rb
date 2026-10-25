require "test_helper"

module Services
  module Books
    module GoodreadsEnrichment
      class GenreMatcherTest < ActiveSupport::TestCase
        def category(name, type: :genre, **attrs)
          ::Books::Category.create!(name: name, category_type: type, **attrs)
        end

        test "matches an active category by name, ignoring case" do
          genre = category("Historical Fiction")
          assert_equal genre, GenreMatcher.new.match("historical fiction")
        end

        test "matches an alternative name" do
          genre = category("Science Fiction", alternative_names: ["Speculative"])
          assert_equal genre, GenreMatcher.new.match("speculative")
        end

        test "twin-matches names that differ only in punctuation and spacing" do
          genre = category("Sci Fi")
          assert_equal genre, GenreMatcher.new.match("Sci-Fi")
        end

        test "a merged category resolves through its canonical target" do
          target = category("Literary")
          category("Literary Fiction", deleted: true, merged_into_id: target.id)
          assert_equal target, GenreMatcher.new.match("Literary Fiction")
        end

        test "a merged category whose target is deleted is no match" do
          target = category("Gone", deleted: true)
          category("Literary Fiction", deleted: true, merged_into_id: target.id)
          assert_nil GenreMatcher.new.match("Literary Fiction")
        end

        test "a deleted category that was not merged never matches" do
          category("Junk", deleted: true)
          assert_nil GenreMatcher.new.match("Junk")
        end

        test "an active match beats a merged one in the same pass" do
          target = category("Elsewhere")
          category("Mystery", type: :genre, deleted: true, merged_into_id: target.id)
          active = category("Mystery", type: :audience)
          assert_equal active, GenreMatcher.new.match("Mystery")
        end

        test "an exact name beats an alternative name and a twin key" do
          category("Thriller Books", alternative_names: ["Thriller"])
          category("Thrill-er")
          exact = category("Thriller", type: :audience)
          assert_equal exact, GenreMatcher.new.match("Thriller")
        end

        test "an alternative name beats a twin key" do
          category("Thrill-er")
          alt = category("Suspense", type: :subject, alternative_names: ["Thriller"])
          assert_equal alt, GenreMatcher.new.match("Thriller")
        end

        test "when several types match, genre beats subject beats audience" do
          audience = category("Young Adult", type: :audience)
          subject = category("Young Adult", type: :subject)
          genre = category("Young Adult", type: :genre)
          assert_equal genre, GenreMatcher.new.match("Young Adult")
          genre.update!(deleted: true)
          assert_equal subject, GenreMatcher.new.match("Young Adult")
          subject.update!(deleted: true)
          assert_equal audience, GenreMatcher.new.match("Young Adult")
        end

        test "a name matching only a location returns nil" do
          category("Paris", type: :location)
          assert_nil GenreMatcher.new.match("Paris")
        end

        test "an unknown or blank name returns nil" do
          assert_nil GenreMatcher.new.match("No Such Genre Anywhere")
          assert_nil GenreMatcher.new.match("")
          assert_nil GenreMatcher.new.match(nil)
        end

        test "matching never creates a category" do
          category("Historical Fiction")
          assert_no_difference "Category.count" do
            matcher = GenreMatcher.new
            assert matcher.match("Historical Fiction")
            assert_nil matcher.match("Unknown")
            assert_nil matcher.match("Sci-Fi")
          end
        end

        test "candidate rows are loaded once per instance" do
          category("Historical Fiction")
          matcher = GenreMatcher.new
          assert matcher.match("Historical Fiction")
          queries = []
          counter = ->(*, payload) { queries << payload[:sql] unless payload[:name] == "SCHEMA" }
          ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
            assert matcher.match("Historical Fiction")
            assert_nil matcher.match("Other")
          end
          assert_empty queries
        end
      end
    end
  end
end
