require "test_helper"

module Services
  module Books
    module AlternateTitles
      class ReviewTest < ActiveSupport::TestCase
        Task = Services::Ai::Tasks::Books::AlternateTitlesReviewTask

        setup do
          @book = books_books(:war_and_peace)
          @chat = ai_chats(:general_chat)
          ::AlternateTitle.where(titleable: @book).delete_all
          @book.update_columns(alternate_titles: [])
          @book.reload
        end

        def row(title, **attrs)
          created = ::AlternateTitle.create!({titleable: @book, title: title, source: :legacy, status: :kept}.merge(attrs))
          @book.update_columns(alternate_titles: ::AlternateTitle.where(titleable: @book).listed.pluck(:title))
          @book.reload
          created
        end

        def verdict(overrides = {})
          {verdict: "not_same_work", category: "other_work", confidence: 0.9, reason: "A different book."}.merge(overrides)
        end

        def respond(results)
          Services::Ai::Result.new(success: true, data: {results: results}, ai_chat: @chat)
        end

        def stub_task(*responses)
          Task.any_instance.stubs(:call).returns(*responses)
        end

        test "same work keeps and records the verdict" do
          r = row("Voyna i mir")
          stub_task(respond("1" => verdict(verdict: "same_work", category: "translation", confidence: 0.95, reason: "Transliteration.")))

          result = Review.call(book: @book)

          assert result.success?
          assert_equal({judged: 1, kept: 1, removed: 0, review: 0, missing: 0}, result.data)
          r.reload
          assert r.kept?
          assert r.verdict_same_work?
          assert r.category_translation?
          assert_equal 0.95, r.confidence
          assert_equal "Transliteration.", r.reason
          assert_equal @chat, r.ai_chat
          assert r.judged_at
          assert r.decided_by_ai?
          assert r.decided_at
        end

        test "confident not same work is removed" do
          r = row("Anna Karenina")
          stub_task(respond("1" => verdict))

          result = Review.call(book: @book)

          assert_equal 1, result.data[:removed]
          r.reload
          assert r.removed?
          assert r.decided_by_ai?
          assert r.decided_at
          assert_equal [], @book.reload.alternate_titles
        end

        test "unsure not same work goes to review" do
          r = row("Anna Karenina")
          stub_task(respond("1" => verdict(confidence: 0.5)))

          result = Review.call(book: @book)

          assert_equal 1, result.data[:review]
          r.reload
          assert r.review?
          assert_nil r.decided_by
          assert_nil r.decided_at
          assert_equal ["Anna Karenina"], @book.reload.alternate_titles
        end

        test "admin rows go to review whatever the confidence" do
          r = row("Anna Karenina", source: :admin)
          stub_task(respond("1" => verdict(confidence: 0.99)))

          Review.call(book: @book)

          assert r.reload.review?
        end

        test "only unjudged rows are sent" do
          judged = row("Voyna i mir", verdict: :same_work, category: :translation, confidence: 0.9, judged_at: Time.current)
          fresh = row("Anna Karenina")
          Task.expects(:new).with { |opts|
            opts[:entries].map(&:title) == ["Anna Karenina"] && opts[:accepted] == ["Voyna i mir"] && opts[:parent] == @book
          }.returns(stub(call: respond("1" => verdict(confidence: 0.5))))

          Review.call(book: @book)

          assert judged.reload.verdict_same_work?
          assert fresh.reload.review?
        end

        test "missing keys are asked once more" do
          a = row("Anna Karenina")
          b = row("The Cossacks")
          stub_task(respond("1" => verdict(confidence: 0.5)), respond("1" => verdict(confidence: 0.5)))

          result = Review.call(book: @book)

          assert_equal 2, result.data[:judged]
          assert_equal 0, result.data[:missing]
          assert a.reload.verdict_not_same_work?
          assert b.reload.verdict_not_same_work?
        end

        test "a title still unanswered is counted missing and left unjudged" do
          a = row("Anna Karenina")
          b = row("The Cossacks")
          stub_task(respond("1" => verdict(confidence: 0.5)), respond({}))

          result = Review.call(book: @book)

          assert_equal 1, result.data[:judged]
          assert_equal 1, result.data[:missing]
          assert a.reload.verdict
          assert_nil b.reload.verdict
        end

        test "long lists are chunked" do
          45.times { |i| row("Title #{i}") }
          sizes = []
          answers = [40, 5].map { |n| respond((1..n).to_h { |i| [i.to_s, verdict(verdict: "same_work", category: "variant")] }) }
          Task.stubs(:new).with { |opts|
            sizes << opts[:entries].size
            opts[:parent] == @book && opts[:entries].first.key == "1"
          }.returns(stub(call: answers[0]), stub(call: answers[1]))

          result = Review.call(book: @book)

          assert_equal [40, 5], sizes
          assert_equal 45, result.data[:judged]
          assert_equal 45, ::AlternateTitle.where(titleable: @book).where.not(verdict: nil).count
        end

        test "a book with nothing unjudged makes no call" do
          row("Voyna i mir", verdict: :same_work, category: :translation, confidence: 0.9)
          Task.expects(:new).never

          result = Review.call(book: @book)

          assert result.success?
          assert_equal({judged: 0, kept: 0, removed: 0, review: 0, missing: 0}, result.data)
        end

        test "a failed call returns failure and writes nothing" do
          r = row("Anna Karenina")
          stub_task(Services::Ai::Result.new(success: false, error: "boom"))

          result = Review.call(book: @book)

          assert_not result.success?
          assert_nil r.reload.verdict
          assert r.kept?
        end
      end
    end
  end
end
