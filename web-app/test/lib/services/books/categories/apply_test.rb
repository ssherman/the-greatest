require "test_helper"

module Services
  module Books
    module Categories
      class ApplyTest < ActiveSupport::TestCase
        setup do
          @book = ::Books::Book.create!(title: "Apply Test Book", first_published_year: 1900, original_language: Language.first)
          @fiction = categories(:books_fiction_genre)
          @nonfiction = categories(:books_nonfiction_genre)
          @n = 0
        end

        def category(type, name = nil, **attrs)
          @n += 1
          ::Books::Category.create!(name: name || "Cat #{type} #{@n}", category_type: type, **attrs)
        end

        def link(cat, source = :legacy) = @book.category_items.create!(category: cat, source: source)

        def sources_of(cat) = CategoryItem.find_by(item: @book, category_id: cat.id)&.source

        def dossier(external: true, book_facts: nil, wikidata: nil, worldcat: nil, goodreads: nil)
          wikidata = {"genres" => ["Unrelated"]} if external && wikidata.nil? && worldcat.nil?
          Categorize::Dossier.new(book: @book, evidence_id: nil, record: {}, book_facts: book_facts,
            wikidata: wikidata, wikipedia: nil, worldcat: worldcat, goodreads: goodreads)
        end

        def entry(cat, confidence = "high")
          {type: cat.category_type, category: cat, proposed: cat.name, confidence: confidence, evidence: "x", via: "id"}
        end

        def answer(book_type: nil, recognized: true, confidence: "high")
          {"recognized" => recognized, "confidence" => confidence, "book_type" => book_type}
        end

        def perform(resolved: [], dossier: self.dossier, answer: self.answer, rejudge: true)
          Apply.call(book: @book, dossier: dossier, answer: answer, resolved: resolved, rejudge: rejudge)
        end

        test "a high entry is added with source ai and support recorded" do
          cat = category("genre", "Satire")
          result = perform(resolved: [entry(cat)], dossier: dossier(wikidata: {"genres" => ["Satire"]}))
          assert_equal [[cat.id, "high", ["wikidata"]]], result.data[:added].map { |a| [a[:id], a[:confidence], a[:support]] }
          assert_equal "ai", sources_of(cat)
        end

        test "item_count of an added category rises by one" do
          cat = category("genre")
          assert_difference -> { cat.reload.item_count }, 1 do
            perform(resolved: [entry(cat)])
          end
        end

        test "medium with support is added, medium without is held back, low is held back" do
          supported = category("genre", "Satire")
          bare = category("genre", "Bare")
          low = category("genre", "Lowly")
          result = perform(resolved: [entry(supported, "medium"), entry(bare, "medium"), entry(low, "low")],
            dossier: dossier(worldcat: {"mapped_genres" => {"genre:Satire" => 1}, "subjects" => []}))
          assert_equal [supported.id], result.data[:added].map { |a| a[:id] }
          assert_equal [[bare.id, "unsupported_medium"], [low.id, "low_confidence"]], result.data[:held_back].map { |h| [h[:id], h[:reason]] }
          assert_nil sources_of(bare)
          assert_nil sources_of(low)
        end

        def five_legacy_genres
          genres = Array.new(5) { category("genre") }
          genres.each { |g| link(g) }
          genres
        end

        test "a high recognized external re-judge removes an unpicked unsupported legacy link, then adds one and caps the next" do
          genres = five_legacy_genres
          picked_a, picked_b, picked_c, picked_d, stale = genres
          wikidata = {"genres" => genres.first(4).map(&:name)}
          fresh = category("genre")
          extra = category("genre")
          result = perform(resolved: [entry(fresh), entry(extra)], dossier: dossier(wikidata: wikidata))
          assert_equal [stale.id], result.data[:removed].map { |r| r[:id] }
          assert_equal [{id: stale.id, name: stale.name, type: "genre", source: "legacy"}], result.data[:removed]
          assert_equal [fresh.id], result.data[:added].map { |a| a[:id] }
          assert_equal [[extra.id, "cap"]], result.data[:held_back].map { |h| [h[:id], h[:reason]] }
          assert result.data[:rejudged]
          assert_nil sources_of(stale)
          assert_equal [:legacy] * 4, [picked_a, picked_b, picked_c, picked_d].map { |g| sources_of(g).to_sym }
        end

        test "nothing is removed when the dossier is not external" do
          genres = five_legacy_genres
          result = perform(dossier: dossier(external: false))
          assert_empty result.data[:removed]
          assert_not result.data[:rejudged]
          assert_equal 5, CategoryItem.where(item: @book, category_id: genres.map(&:id)).count
        end

        test "nothing is removed when rejudge is false, unrecognized, or not high" do
          five_legacy_genres
          [perform(rejudge: false), perform(answer: answer(recognized: false)), perform(answer: answer(confidence: "medium"))].each do |result|
            assert_empty result.data[:removed]
            assert_not result.data[:rejudged]
          end
        end

        test "a legacy country stays when a child location is resolved" do
          us = category("location", "Testland")
          chicago = category("location", "Testville", parent: us)
          link(us)
          result = perform(resolved: [entry(chicago)])
          assert_empty result.data[:removed]
          assert_equal "legacy", sources_of(us)
          assert_equal "ai", sources_of(chicago)
        end

        test "a legacy link backed by a goodreads shelf stays" do
          shelfy = category("genre", "Shelfy Fiction")
          link(shelfy)
          result = perform(dossier: dossier(goodreads: {"genres" => ["shelfy fiction"]}))
          assert_empty result.data[:removed]
          assert_equal "legacy", sources_of(shelfy)
        end

        test "legacy audience, Fiction and Nonfiction links are never removed" do
          kids = category("audience", "Kidz")
          link(kids)
          link(@fiction)
          result = perform
          assert_empty result.data[:removed]
          assert_equal %w[legacy legacy], [sources_of(kids), sources_of(@fiction)]
        end

        test "links of other sources are never removed" do
          cats = %i[admin goodreads worldcat ai].map { |source| category("subject").tap { |c| link(c, source) } }
          result = perform
          assert_empty result.data[:removed]
          assert_equal %w[admin goodreads worldcat ai], cats.map { |c| sources_of(c) }
        end

        test "removal frees room under the cap for the same type only" do
          subjects = Array.new(8) { category("subject") }.each { |s| link(s) }
          fresh = category("subject")
          result = perform(resolved: [entry(fresh)], dossier: dossier(wikidata: {"main_subjects" => subjects.first(7).map(&:name)}))
          assert_equal [subjects.last.id], result.data[:removed].map { |r| r[:id] }
          assert_equal [fresh.id], result.data[:added].map { |a| a[:id] }
        end

        test "Fiction does not count against the genre cap" do
          link(@fiction)
          4.times { link(category("genre")) }
          result = perform(resolved: [entry(category("genre"))], rejudge: false)
          assert_equal 1, result.data[:added].size
        end

        test "direct admin links count toward the cap" do
          5.times { link(category("genre"), :admin) }
          cat = category("genre")
          assert_equal "cap", perform(resolved: [entry(cat)]).data[:held_back].first[:reason]
        end

        test "a judged type the book contradicts is a type_conflict and the link survives" do
          link(@nonfiction)
          result = perform(answer: answer(book_type: {"value" => "fiction", "confidence" => "high", "evidence" => "x"}))
          assert_equal "type_conflict", result.data[:type][:reason]
          assert_not result.data[:type][:applied]
          assert_equal "legacy", sources_of(@nonfiction)
          assert_nil sources_of(@fiction)
        end

        test "the type is applied with source ai when the book has none and the judge is high" do
          result = perform(answer: answer(book_type: {"value" => "nonfiction", "confidence" => "high", "evidence" => "x"}))
          assert result.data[:type][:applied]
          assert_equal "applied", result.data[:type][:reason]
          assert_equal "ai", sources_of(@nonfiction)
        end

        test "type reasons: held, not_high, no_type for poetry, religious and none" do
          link(@fiction)
          assert_equal "held", perform(answer: answer(book_type: {"value" => "fiction", "confidence" => "high"})).data[:type][:reason]
          CategoryItem.where(item: @book).destroy_all
          assert_equal "not_high", perform(answer: answer(book_type: {"value" => "fiction", "confidence" => "medium"})).data[:type][:reason]
          %w[poetry religious unknown].each do |value|
            assert_equal "no_type", perform(answer: answer(book_type: {"value" => value, "confidence" => "high"})).data[:type][:reason]
          end
          assert_equal "no_type", perform.data[:type][:reason]
          assert_empty CategoryItem.where(item: @book)
        end

        test "book_facts disagreeing with a judged high type blocks it" do
          result = perform(answer: answer(book_type: {"value" => "fiction", "confidence" => "high"}),
            dossier: dossier(book_facts: {"book_type" => {"value" => "nonfiction"}}))
          assert_equal "book_facts_disagrees", result.data[:type][:reason]
          assert_nil sources_of(@fiction)
        end

        test "book_facts that agrees lets the type through" do
          result = perform(answer: answer(book_type: {"value" => "fiction", "confidence" => "high"}),
            dossier: dossier(book_facts: {"book_type" => {"value" => "fiction"}}))
          assert_equal "applied", result.data[:type][:reason]
        end

        test "a picked legacy link becomes ai and is confirmed, not added" do
          cat = category("genre")
          link(cat)
          result = perform(resolved: [entry(cat)])
          assert_equal [{id: cat.id, name: cat.name, type: "genre", from: "legacy"}], result.data[:confirmed]
          assert_empty result.data[:added]
          assert_equal "ai", sources_of(cat)
        end

        test "a picked inherited location becomes ai" do
          us = category("location", "Landia")
          chicago = category("location", "Chicagoish", parent: us)
          link(chicago)
          ::Categories::AncestorReconciler.call(item_ids: [@book.id])
          assert_equal "inherited", sources_of(us)
          result = perform(resolved: [entry(us)], rejudge: false)
          assert_equal [[us.id, "inherited"]], result.data[:confirmed].map { |c| [c[:id], c[:from]] }
          assert_equal "ai", sources_of(us)
        end

        test "an existing link of another source is left alone and not counted as added" do
          cat = category("subject")
          link(cat, :admin)
          result = perform(resolved: [entry(cat)])
          assert_empty result.data[:added] + result.data[:confirmed] + result.data[:held_back]
          assert_equal "admin", sources_of(cat)
        end

        test "the audience cap is 1" do
          first = category("audience")
          second = category("audience")
          result = perform(resolved: [entry(first), entry(second)])
          assert_equal [first.id], result.data[:added].map { |a| a[:id] }
          assert_equal [[second.id, "cap"]], result.data[:held_back].map { |h| [h[:id], h[:reason]] }
        end

        test "high entries are added before medium ones when the cap bites" do
          3.times { link(category("audience"), :admin) } # fills nothing relevant to subjects
          7.times { link(category("subject"), :admin) }
          medium = category("subject", "Medsubj")
          high = category("subject", "Highsubj")
          result = perform(resolved: [entry(medium, "medium"), entry(high)], dossier: dossier(wikidata: {"main_subjects" => ["Medsubj"]}))
          assert_equal [high.id], result.data[:added].map { |a| a[:id] }
          assert_equal [[medium.id, "cap"]], result.data[:held_back].map { |h| [h[:id], h[:reason]] }
        end

        test "the ancestor reconciler runs once when something was written and not otherwise" do
          ::Categories::AncestorReconciler.expects(:call).with(item_ids: [@book.id]).once
          perform(resolved: [entry(category("genre")), entry(category("genre"))])

          ::Categories::AncestorReconciler.expects(:call).never
          perform(resolved: [])
        end

        test "string and symbol keyed answers both work" do
          result = perform(answer: {recognized: true, confidence: "high", book_type: {value: "fiction", confidence: "high"}})
          assert_equal "applied", result.data[:type][:reason]
        end
      end
    end
  end
end
