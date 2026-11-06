require "test_helper"

module Services
  module Books
    module GenrePlan
      class MapTest < ActiveSupport::TestCase
        setup do
          ::Books::Category.where(category_type: :genre).update_all(deleted: true)
          @vegetarian = ::Books::Category.create!(name: "Vegetarian", category_type: :genre, item_count: 2)
          @hockey_romance = ::Books::Category.create!(name: "Hockey Romance", category_type: :genre, item_count: 1)
          @dakota = ::Books::Category.create!(name: "Dakotas", category_type: :genre)
          @hockey = ::Books::Category.create!(name: "Hockey", category_type: :subject)
          @path = Rails.root.join("tmp", "map_test_#{SecureRandom.hex(4)}.yml")
          PlanFile.new({"run" => "g", "genres" => [{"name" => "Romance", "definition" => "x"}],
            "audiences" => PlanFile::AUDIENCES.map { |n, d| {"name" => n, "definition" => d} }, "decisions" => {}}, path: @path).write
          @worldcat = ::Books::WorldCat::GenreMap.new("terms" => {"Hockey stories" => {"verdict" => "genre", "genre" => "Hockey Romance"}})
        end

        teardown { FileUtils.rm_f(@path) }

        def answer(key, overrides)
          {key: key, action: "delete", to: nil, into: [], into_subjects: [], as: nil, also: [], worldcat: nil, worldcat_terms: {}, reason: "r"}.merge(overrides)
        end

        def respond(results)
          Services::Ai::Result.new(success: true, data: {results: results})
        end

        test "writes one decision per genre, resolving subjects and dropping unknown places" do
          Services::Ai::Tasks::Books::GenreMapTask.any_instance.stubs(:call).returns(respond(
            "1" => answer("1", action: "subject", as: "Vegetarianism"),
            "2" => answer("2", action: "split", into: ["Romance"], into_subjects: ["Hockey"], worldcat_terms: {"Hockey stories" => ["Romance"]}),
            "3" => answer("3", action: "location", as: "Dakotas")
          ))

          result = Map.call(path: @path, map: @worldcat)

          decisions = PlanFile.load(@path).decisions
          assert_equal 3, result.data[:mapped]
          assert_equal({"name" => "Vegetarian", "action" => "subject", "reason" => "r", "books" => 2, "saved_searches" => 0, "as" => "Vegetarianism"}, decisions[@vegetarian.id])
          assert_equal ["Romance", {"subject" => "Hockey", "target_id" => @hockey.id}], decisions[@hockey_romance.id]["into"]
          assert_equal({"Hockey stories" => ["Romance"]}, decisions[@hockey_romance.id]["worldcat_terms"])
          assert_equal "delete", decisions[@dakota.id]["action"]
          assert_equal "no such location: Dakotas", decisions[@dakota.id]["reason"]
        end

        test "passes the WorldCat terms that target a split genre as input" do
          captured = nil
          Services::Ai::Tasks::Books::GenreMapTask.stubs(:new).with { |**kw| captured = kw[:entries] }.returns(stub(call: respond(
            "1" => answer("1", {}), "2" => answer("2", {}), "3" => answer("3", {})
          )))

          Map.call(path: @path, map: @worldcat)

          assert_equal [[], ["Hockey stories"], []], captured.map(&:worldcat_terms)
        end

        test "WorldCat terms are found whatever the case of the genre name" do
          captured = nil
          worldcat = ::Books::WorldCat::GenreMap.new("terms" => {"Hockey stories" => {"verdict" => "genre", "genre" => "hockey romance"}, "Puck tales" => {"verdict" => "genre", "genre" => "Hockey romance"}})
          Services::Ai::Tasks::Books::GenreMapTask.stubs(:new).with { |**kw| captured = kw[:entries] }.returns(stub(call: respond(
            "1" => answer("1", {}), "2" => answer("2", {}), "3" => answer("3", {})
          )))

          Map.call(path: @path, map: worldcat)

          assert_equal [[], ["Hockey stories", "Puck tales"], []], captured.map(&:worldcat_terms)
        end

        test "a subject answer naming an existing subject gets its target_id" do
          Services::Ai::Tasks::Books::GenreMapTask.any_instance.stubs(:call).returns(respond(
            "1" => answer("1", action: "subject", as: "hockey"), "2" => answer("2", {}), "3" => answer("3", {})
          ))

          Map.call(path: @path, map: @worldcat)

          assert_equal [@hockey.id, "Hockey"], PlanFile.load(@path).decisions[@vegetarian.id].values_at("target_id", "as")
        end

        test "a split whose subject half does not exist drops it and says so in the reason" do
          Services::Ai::Tasks::Books::GenreMapTask.any_instance.stubs(:call).returns(respond(
            "1" => answer("1", {}), "3" => answer("3", {}),
            "2" => answer("2", action: "split", into: ["Romance"], into_subjects: ["Nonesuch"], worldcat_terms: {"Hockey stories" => ["Romance"]})
          ))

          Map.call(path: @path, map: @worldcat)

          decision = PlanFile.load(@path).decisions[@hockey_romance.id]
          assert_equal ["Romance"], decision["into"]
          assert_includes decision["reason"], "no subject named Nonesuch"
        end

        test "a second run maps nothing; a failed batch writes nothing" do
          Services::Ai::Tasks::Books::GenreMapTask.any_instance.stubs(:call).returns(Services::Ai::Result.new(success: false, error: "bad name"))
          failed = Map.call(path: @path, map: @worldcat)
          assert_equal [0, 1, 3], failed.data.values_at(:mapped, :failed_batches, :remaining)
          assert_empty PlanFile.load(@path).decisions

          Services::Ai::Tasks::Books::GenreMapTask.any_instance.stubs(:call).returns(respond(
            "1" => answer("1", {}), "2" => answer("2", {}), "3" => answer("3", {})
          ))
          Map.call(path: @path, map: @worldcat)
          Services::Ai::Tasks::Books::GenreMapTask.any_instance.expects(:call).never
          assert_equal 0, Map.call(path: @path, map: @worldcat).data[:mapped]
        end
      end
    end
  end
end
