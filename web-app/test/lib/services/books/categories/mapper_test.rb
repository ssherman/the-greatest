require "test_helper"

module Services
  module Books
    module Categories
      class MapperTest < ActiveSupport::TestCase
        setup do
          @book = books_books(:war_and_peace)
          @fiction = categories(:books_fiction_genre)
          @novels = categories(:books_novels_genre)
          @kids = ::Books::Category.create!(name: "Children's", category_type: "audience")
          @vocabulary = [@fiction, @novels, @kids]
        end

        def subject(name, **attrs) = ::Books::Category.create!(name: name, category_type: "subject", **attrs)

        def location(name, parent: nil, **attrs) = ::Books::Category.create!(name: name, category_type: "location", parent: parent, **attrs)

        def answer(genres: [], audience: {id: nil}, subjects: [], locations: [])
          {genres: genres, audience: audience, subjects: subjects, locations: locations}
        end

        def subj(name) = {name: name, confidence: "high", evidence: "Wikidata"}

        def loc(name, kind: "real", parent: nil) = {name: name, kind: kind, parent: parent, confidence: "high", evidence: "Wikipedia"}

        def map(ans) = Mapper.call(book: @book, answer: ans, vocabulary: @vocabulary)

        def chooser_returns(*choices)
          result = Services::Ai::Result.new(success: true, data: {choices: choices}, ai_chat: nil)
          Services::Ai::Tasks::Books::CategoryChoiceTask.any_instance.expects(:call).once.returns(result)
        end

        test "a genre id from the vocabulary resolves with its confidence and evidence" do
          result = map(answer(genres: [{id: @novels.id, confidence: "high", evidence: "WorldCat"}]))
          assert result.success?
          entry = result.data[:resolved].first
          assert_equal [@novels, "genre", "id", "high", "WorldCat"], entry.values_at(:category, :type, :via, :confidence, :evidence)
          assert_empty result.data[:unmatched]
        end

        test "an id outside the vocabulary, a Fiction id and an audience as a genre are invalid_id" do
          other = categories(:books_classics_genre)
          ans = answer(genres: [{id: 0, confidence: "high", evidence: "x"}, {id: @fiction.id, confidence: "high", evidence: "x"},
            {id: other.id, confidence: "high", evidence: "x"}, {id: @kids.id, confidence: "high", evidence: "x"}])
          result = map(ans)
          assert_empty result.data[:resolved]
          assert_equal %w[invalid_id] * 4, result.data[:unmatched].map { |u| u[:via] }
        end

        test "the audience resolves by id, a genre id there is invalid, and a null audience is skipped" do
          assert_equal @kids, map(answer(audience: {id: @kids.id, confidence: "medium", evidence: "x"})).data[:resolved].first[:category]
          bad = map(answer(audience: {id: @novels.id, confidence: "medium", evidence: "x"}))
          assert_equal [{type: "audience", proposed: @novels.id.to_s, via: "invalid_id"}], bad.data[:unmatched]
          none = map(answer)
          assert_empty none.data[:resolved] + none.data[:unmatched]
        end

        test "string keys work at every level" do
          result = map(answer(genres: [{id: @novels.id, confidence: "high", evidence: "x"}]).deep_stringify_keys)
          assert_equal [@novels], result.data[:resolved].map { |r| r[:category] }
        end

        test "an exact subject match goes through an alternative name" do
          chess = subject("Chess", alternative_names: ["Game of Kings"])
          Services::Ai::Tasks::Books::CategoryChoiceTask.any_instance.expects(:call).never
          result = map(answer(subjects: [subj("game of kings!")]))
          assert_equal [[chess, "exact"]], result.data[:resolved].map { |r| [r[:category], r[:via]] }
        end

        test "a merged subject follows its target, by name and by alternative name" do
          target = subject("World War II")
          subject("WWII", deleted: true, merged_into_id: target.id, alternative_names: ["Second World War"])
          Services::Ai::Tasks::Books::CategoryChoiceTask.any_instance.expects(:call).never
          result = map(answer(subjects: [subj("wwii"), subj("Second World War")]))
          assert_equal [[target, "merged"]], result.data[:resolved].map { |r| [r[:category], r[:via]] }
        end

        test "a merge whose target is deleted is not accepted" do
          dead = subject("Dead End", deleted: true)
          subject("Old Name", deleted: true, merged_into_id: dead.id)
          result = map(answer(subjects: [subj("Old Name")]))
          assert_equal [{type: "subject", proposed: "Old Name", via: "no_candidate"}], result.data[:unmatched]
        end

        test "Georgia with a United States hint when only the Caucasus Georgia exists goes to the chooser and can be declined" do
          caucasus = location("Caucasus")
          georgia = location("Georgia", parent: caucasus)
          Services::Ai::Tasks::Books::CategoryChoiceTask.expects(:new).with do |args|
            labels = args[:questions].first[:candidates].map { |c| c[:label] }
            labels.include?("Georgia › Caucasus") && args[:questions].first[:candidates].map { |c| c[:id] }.include?(georgia.id)
          end.returns(stub(call: Services::Ai::Result.new(success: true, data: {choices: [{proposed: "Georgia", category_id: nil}]}, ai_chat: nil)))
          result = map(answer(locations: [loc("Georgia", parent: "United States")]))
          assert_empty result.data[:resolved]
          assert_equal [{type: "location", proposed: "Georgia", via: "declined"}], result.data[:unmatched]
        end

        test "the same Georgia with the Caucasus hint is exact" do
          georgia = location("Georgia", parent: location("Caucasus"))
          Services::Ai::Tasks::Books::CategoryChoiceTask.any_instance.expects(:call).never
          result = map(answer(locations: [loc("Georgia", parent: "Caucasus")]))
          assert_equal [[georgia, "exact"]], result.data[:resolved].map { |r| [r[:category], r[:via]] }
        end

        test "a comma hint matches on its container part and ignores the place's own name" do
          georgia = location("Georgia", parent: location("Caucasus"))
          Services::Ai::Tasks::Books::CategoryChoiceTask.any_instance.expects(:call).never
          assert_equal [georgia], map(answer(locations: [loc("Georgia", parent: "Georgia, Caucasus")])).data[:resolved].map { |r| r[:category] }
          chooser_returns({proposed: "Georgia", category_id: nil})
          assert_empty map(answer(locations: [loc("Georgia", parent: "Georgia, United States")])).data[:resolved]
        end

        test "a place with no hint and one exact hit is exact" do
          paris = location("Paris", parent: location("France"))
          assert_equal [paris], map(answer(locations: [loc("Paris")])).data[:resolved].map { |r| r[:category] }
        end

        test "two exact location hits are ambiguous: the chooser sees the exact hits first" do
          us = location("United States")
          ga_us = location("Georgia", parent: us)
          ga_cau = location("Georgia", parent: location("Caucasus"))
          Services::Ai::Tasks::Books::CategoryChoiceTask.expects(:new).with do |args|
            args[:questions].first[:candidates].map { |c| c[:id] }.first(2).sort == [ga_us.id, ga_cau.id].sort
          end.returns(stub(call: Services::Ai::Result.new(success: true, data: {choices: [{proposed: "Georgia", category_id: ga_us.id}]}, ai_chat: nil)))
          result = map(answer(locations: [loc("Georgia")]))
          assert_equal [[ga_us, "chosen"]], result.data[:resolved].map { |r| [r[:category], r[:via]] }
        end

        test "one chooser call covers every unresolved name" do
          a = subject("Alpha Quasar Studies")
          b = subject("Beta Quasar Studies")
          c = subject("Gamma Quasar Studies")
          chooser_returns({proposed: "Alpha Quasar", category_id: a.id}, {proposed: "Beta Quasar", category_id: b.id},
            {proposed: "Gamma Quasar", category_id: c.id})
          result = map(answer(subjects: [subj("Alpha Quasar"), subj("Beta Quasar"), subj("Gamma Quasar")]))
          assert_equal [a, b, c], result.data[:resolved].map { |r| r[:category] }
          assert_equal %w[chosen] * 3, result.data[:resolved].map { |r| r[:via] }
        end

        test "the chat from the chooser is returned" do
          s = subject("Quasar Studies")
          chat = AiChat.new
          Services::Ai::Tasks::Books::CategoryChoiceTask.any_instance.expects(:call)
            .returns(Services::Ai::Result.new(success: true, data: {choices: [{proposed: "Quasar", category_id: s.id}]}, ai_chat: chat))
          assert_same chat, map(answer(subjects: [subj("Quasar")])).data[:ai_chat]
        end

        test "no chooser call when nothing is unresolved or nothing has candidates" do
          subject("Chess")
          Services::Ai::Tasks::Books::CategoryChoiceTask.any_instance.expects(:call).never
          result = map(answer(subjects: [subj("Chess"), subj("Zzzyzx Nonexistent")]))
          assert_equal ["Chess"], result.data[:resolved].map { |r| r[:proposed] }
          assert_equal [{type: "subject", proposed: "Zzzyzx Nonexistent", via: "no_candidate"}], result.data[:unmatched]
          assert_nil result.data[:ai_chat]
        end

        test "a chooser id outside the candidates is declined" do
          subject("Quasar Studies")
          outsider = subject("Entirely Different")
          chooser_returns({proposed: "Quasar", category_id: outsider.id})
          result = map(answer(subjects: [subj("Quasar")]))
          assert_empty result.data[:resolved]
          assert_equal [{type: "subject", proposed: "Quasar", via: "declined"}], result.data[:unmatched]
        end

        test "a failed chooser call fails the mapping" do
          subject("Quasar Studies")
          Services::Ai::Tasks::Books::CategoryChoiceTask.any_instance.expects(:call).returns(Services::Ai::Result.new(success: false, error: "boom"))
          result = map(answer(subjects: [subj("Quasar")]))
          refute result.success?
          assert_equal ["boom"], result.errors
        end

        test "an unmatched fictional main setting resolves to the Fictional Location root; a second one does not" do
          root = location("Fictional Location")
          result = map(answer(locations: [loc("Zzzyzx Land", kind: "fictional"), loc("Qwxyz Land", kind: "fictional")]))
          assert_equal [[root, "fictional_root", "Zzzyzx Land"]], result.data[:resolved].map { |r| [r[:category], r[:via], r[:proposed]] }
          assert_equal [{type: "location", proposed: "Qwxyz Land", via: "no_candidate"}], result.data[:unmatched]
          second_only = map(answer(locations: [loc("Zzzyzx Land"), loc("Qwxyz Land", kind: "fictional")]))
          assert_empty second_only.data[:resolved].select { |r| r[:via] == "fictional_root" }
        end

        test "a fictional location that matches the fictional subtree resolves there" do
          root = location("Fictional Location")
          shire = location("The Shire", parent: root)
          result = map(answer(locations: [loc("The Shire", kind: "fictional")]))
          assert_equal [[shire, "exact"]], result.data[:resolved].map { |r| [r[:category], r[:via]] }
        end

        test "a real Paris never resolves to a fictional Paris" do
          root = location("Fictional Location")
          location("Paris", parent: root)
          result = map(answer(locations: [loc("Paris")]))
          assert_empty result.data[:resolved]
          assert_equal [{type: "location", proposed: "Paris", via: "no_candidate"}], result.data[:unmatched]
        end

        test "two answers that resolve to one category keep the first" do
          chess = subject("Chess", alternative_names: ["Game of Kings"])
          result = map(answer(subjects: [subj("Chess"), subj("Game of Kings")]))
          assert_equal [[chess, "Chess"]], result.data[:resolved].map { |r| [r[:category], r[:proposed]] }
          assert_empty result.data[:unmatched]
        end

        test "a blank name is unmatched" do
          result = map(answer(subjects: [subj("")]))
          assert_equal [{type: "subject", proposed: "", via: "no_candidate"}], result.data[:unmatched]
        end
      end
    end
  end
end
