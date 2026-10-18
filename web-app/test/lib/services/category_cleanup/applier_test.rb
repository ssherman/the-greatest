require "test_helper"

module Services
  module CategoryCleanup
    class ApplierTest < ActiveSupport::TestCase
      setup do
        @book = books_books(:war_and_peace)
      end

      def location(name, links: 1, type: :location)
        record = ::Books::Category.create!(name: name, category_type: type)
        CategoryItem.create!(category: record, item: @book) if links.positive?
        record
      end

      def decide(category, action, decided_by: :rule, **attrs)
        CategoryCleanupDecision.create!({
          category: category, run: "r1", stage: "rules", action: action, decided_by: decided_by,
          category_snapshot: CategoryCleanupDecision.snapshot_of(category)
        }.merge(attrs))
      end

      test "applies renames, merges, retypes, parents and deletes, then reconciles" do
        us = location("United States", links: 0)
        typo = location("Chicgo")
        twin = location("Chicago, Illinois")
        hope = location("Hope")
        junk = location("61)")
        rename = decide(typo, :rename, new_name: "Chicago")
        merge = decide(twin, :merge, target_category: typo)
        retype = decide(hope, :retype, new_category_type: ::Category.category_types["subject"])
        parent = decide(typo, :set_parent, parent_chain: ["United States"])
        delete = decide(junk, :delete)

        result = Applier.call(run: "r1")

        assert_equal "Chicago", typo.reload.name
        assert_equal typo, twin.reload.merged_into
        assert hope.reload.subject?
        assert_equal us.id, typo.parent_id
        assert junk.reload.deleted?
        assert CategoryItem.exists?(category: us, item: @book, source: :inherited)
        assert_equal %w[applied] * 5, [rename, merge, retype, parent, delete].map { |d| d.reload.status }
        assert_equal 1, result.data["merge"]
      end

      test "a chain parent merged into the place itself is skipped for the next name" do
        germany = location("Germany")
        berlin = location("Berlin")
        state = location("Berlin (state)")
        merge = decide(state, :merge, target_category: berlin)
        parent = decide(berlin, :set_parent, parent_chain: ["Berlin (state)", "Germany", "Europe"])

        Applier.call(run: "r1")

        assert_equal berlin, state.reload.merged_into
        assert_equal germany.id, berlin.reload.parent_id
        assert_equal %w[applied applied], [merge, parent].map { |d| d.reload.status }
      end

      test "a two-way merge keeps the more-linked category and its rename" do
        gods = location("Gods", type: :subject)
        deities = location("deities", type: :subject)
        gods.update_column(:item_count, 384)
        deities.update_column(:item_count, 190)
        # Decided in that order (the head goes most-linked first), so id order
        # alone would merge Gods into the smaller deities.
        gods_merge = decide(gods, :merge, target_category: deities)
        deities_merge = decide(deities, :merge, target_category: gods)
        gods_rename = decide(gods, :rename, new_name: "Gods and Goddesses")

        result = Applier.call(run: "r1")

        assert_equal gods, deities.reload.merged_into
        assert_not gods.reload.deleted?
        assert_equal "Gods and Goddesses", gods.name
        assert_equal %w[stale applied applied], [gods_merge, deities_merge, gods_rename].map { |d| d.reload.status }
        assert_match "merge cycle", gods_merge.error
        assert_equal 0, result.data["failed"]
      end

      test "a cycle is not broken at a member that also has a delete, so no merged links are deleted" do
        gods = location("Gods", type: :subject)
        deities = location("Deities", type: :subject)
        gods.update_column(:item_count, 384)
        deities.update_column(:item_count, 190)
        gods_merge = decide(gods, :merge, target_category: deities)
        deities_merge = decide(deities, :merge, target_category: gods)
        gods_delete = decide(gods, :delete)

        Applier.call(run: "r1")

        assert_equal deities, gods.reload.merged_into
        assert_not deities.reload.deleted?
        assert CategoryItem.exists?(category: deities, item: @book)
        assert_equal %w[applied stale stale], [gods_merge, deities_merge, gods_delete].map { |d| d.reload.status }
      end

      test "a cycle whose members all have another terminal decision is left unbroken" do
        a = location("Alpha", type: :subject)
        b = location("Beta", type: :subject)
        a_merge = decide(a, :merge, target_category: b)
        b_merge = decide(b, :merge, target_category: a)
        decide(a, :delete)
        decide(b, :delete)

        Applier.call(run: "r1")

        assert_equal b, a.reload.merged_into
        assert_not b.reload.deleted?
        assert_equal %w[applied failed], [a_merge, b_merge].map { |d| d.reload.status }
      end

      test "a longer merge cycle and a chain into it all end in the most-linked member" do
        a = location("Aliens", type: :subject)
        b = location("Extraterrestrials", type: :subject)
        c = location("Alien Life", type: :subject)
        d = location("Extraterrestrial Life", type: :subject)
        {a => 304, b => 90, c => 171, d => 50}.each { |category, count| category.update_column(:item_count, count) }
        decide(a, :merge, target_category: b)
        decide(b, :merge, target_category: c)
        decide(c, :merge, target_category: a)
        decide(d, :merge, target_category: c)

        result = Applier.call(run: "r1")

        assert_not a.reload.deleted?
        assert_equal [a, a, a], [b, c, d].map { |category| category.reload.merged_into }
        assert_equal [3, 1, 0], [result.data["merge"], result.data["stale"], result.data["failed"]]
      end

      test "a chain that names only the place itself fails" do
        berlin = location("Berlin")
        state = location("Berlin (state)")
        decide(state, :merge, target_category: berlin)
        parent = decide(berlin, :set_parent, parent_chain: ["Berlin (state)"])

        Applier.call(run: "r1")

        assert_nil berlin.reload.parent_id
        assert parent.reload.failed?
        assert_match "its own parent", parent.error
      end

      test "creates missing chain parents with their own parents and records them as kept" do
        chicago = location("Chicago")
        decide(chicago, :set_parent, parent_chain: ["Illinois", "United States", "North America"])

        result = Applier.call(run: "r1")

        illinois = ::Books::Category.find_by!(name: "Illinois", category_type: :location)
        assert_equal ["United States", "North America"], illinois.ancestors.map(&:name)
        assert_equal illinois, chicago.reload.parent
        assert_equal 3, result.data["created"]
        assert CategoryCleanupDecision.exists?(category: illinois, stage: "apply", action: :keep, status: :applied)
        assert CategoryItem.exists?(category: illinois.parent.parent, item: @book, source: :inherited)
      end

      test "a category changed after propose gets stale decisions" do
        place = location("Chicgo")
        decision = decide(place, :rename, new_name: "Chicago")
        place.update!(name: "Chicago, IL")

        Applier.call(run: "r1")

        assert decision.reload.stale?
        assert_equal "Chicago, IL", place.reload.name
      end

      test "a failing decision is marked failed and the rest still apply" do
        gone = location("Gone Target")
        source = location("Source")
        ok = location("chicago")
        failing = decide(source, :merge, target_category: gone)
        gone.update_columns(deleted: true)
        rename = decide(ok, :rename, new_name: "Chicago")

        Applier.call(run: "r1")

        assert failing.reload.failed?
        assert_match "gone", failing.error
        assert rename.reload.applied?
      end

      test "re-running is a no-op, including after a crash between phases" do
        typo = location("Chicgo")
        us = location("United States")
        rename = decide(typo, :rename, new_name: "Chicago")
        decide(typo, :set_parent, parent_chain: ["United States"])
        # Simulate a crash after the rename phase: the rename landed, the set_parent didn't.
        typo.update!(name: "Chicago")
        rename.update!(status: :applied)

        Applier.call(run: "r1")
        assert_equal us, typo.reload.parent

        assert_no_difference -> { CategoryCleanupDecision.applied.count } do
          result = Applier.call(run: "r1")
          assert_equal 0, result.data.values.sum
        end
      end

      test "only_rules applies rule decisions and leaves ai ones proposed" do
        rule_place = location("paris")
        ai_place = location("Lyons")
        decide(rule_place, :rename, new_name: "Paris")
        ai = decide(ai_place, :rename, new_name: "Lyon", decided_by: :ai)

        Applier.call(run: "r1", only_rules: true)

        assert_equal "Paris", rule_place.reload.name
        assert ai.reload.proposed?
      end

      test "never touches a protected category" do
        fiction = categories(:books_fiction_genre)
        ::Books::Category.stubs(:protected_ids).returns([fiction.id])
        decision = decide(fiction, :rename, new_name: "Fiction Books")

        Applier.call(run: "r1")

        assert decision.reload.failed?
        assert_equal "Fiction", fiction.reload.name
      end

      test "leaves music categories alone" do
        rock = categories(:music_rock_genre)
        before = [rock.attributes, CategoryItem.where(category: rock).pluck(:id, :source)]
        decide(location("paris"), :rename, new_name: "Paris")

        Applier.call(run: "r1")

        assert_equal before, [rock.reload.attributes, CategoryItem.where(category: rock).pluck(:id, :source)]
      end

      test "refuses to delete a place that has places under it" do
        parent = location("Somewhere")
        ::Books::Category.create!(name: "Inside", category_type: :location, parent: parent)
        decision = decide(parent, :delete)

        Applier.call(run: "r1")

        assert decision.reload.failed?
        refute parent.reload.deleted?
      end

      test "a rules delete beats an ai rename: delete applies, rename goes stale" do
        place = location("Chicgo")
        delete = decide(place, :delete)
        rename = decide(place, :rename, new_name: "Chicago", decided_by: :ai, stage: "locations_head")

        assert_nothing_raised { Applier.call(run: "r1") }

        assert delete.reload.applied?
        assert rename.reload.stale?
        assert_equal "superseded by delete decision ##{delete.id}", rename.error
        assert place.reload.deleted?
        assert_equal "Chicgo", place.name
      end

      test "a retype beats a delete: retype applies, delete goes stale" do
        place = location("Hope")
        delete = decide(place, :delete)
        retype = decide(place, :retype, new_category_type: ::Category.category_types["subject"], decided_by: :ai, stage: "locations_head")

        Applier.call(run: "r1")

        assert retype.reload.applied?
        assert delete.reload.stale?
        assert place.reload.subject?
        refute place.deleted?
      end

      test "a merge beats a delete and supersedes a rename and a keep" do
        target = location("Chicago")
        place = location("Chicgo")
        other = location("paris")
        delete = decide(place, :delete)
        merge = decide(place, :merge, target_category: target, decided_by: :ai, stage: "locations_head")
        rename = decide(place, :rename, new_name: "Chicagoo")
        keep = decide(place, :keep)
        unrelated = decide(other, :rename, new_name: "Paris")

        result = Applier.call(run: "r1")

        assert merge.reload.applied?
        assert_equal %w[stale stale stale], [delete, rename, keep].map { |d| d.reload.status }
        assert_equal target, place.reload.merged_into
        assert unrelated.reload.applied?
        assert_equal 3, result.data["stale"]
        assert_equal 0, result.data["failed"]
      end

      test "a terminal decision on a category already gone fails cleanly" do
        place = location("Chicgo")
        decision = decide(place, :delete)
        place.update_columns(deleted: true)
        decision.update_columns(category_snapshot: decision.category_snapshot.merge("deleted" => true))

        result = nil
        assert_nothing_raised { result = Applier.call(run: "r1") }

        assert decision.reload.failed?
        assert_match "category is gone", decision.error
        assert_equal 1, result.data["failed"]
      end

      test "a decision on a non-books category fails as not a books category" do
        rock = categories(:music_rock_genre)
        rock_name = rock.name
        decision = CategoryCleanupDecision.create!(
          category: rock, run: "r1", stage: "rules", action: :rename, decided_by: :rule, new_name: "Rock Music",
          category_snapshot: CategoryCleanupDecision.snapshot_of(rock)
        )

        Applier.call(run: "r1")

        assert decision.reload.failed?
        assert_match "not a books category", decision.error
        assert_equal rock_name, rock.reload.name
      end

      test "result data carries every key, zero when unused" do
        result = Applier.call(run: "nothing-here")

        assert_equal %w[rename merge split retype set_parent delete keep created stale failed].sort, result.data.keys.sort
        assert_equal 0, result.data.values.sum
      end

      test "a rename keeps the old name as an alternative, so a chain naming it creates nothing" do
        calcutta = location("Calcutta")
        india = location("India", links: 0)
        howrah = location("Howrah")
        rename = decide(calcutta, :rename, new_name: "Kolkata")
        parent = decide(howrah, :set_parent, parent_chain: ["Calcutta"])

        result = Applier.call(run: "r1")

        assert rename.reload.applied?
        assert parent.reload.applied?
        assert_equal 0, result.data["created"]
        assert_nil ::Books::Category.find_by(name: "Calcutta")
        assert_equal calcutta, howrah.reload.parent
        assert_equal ["Calcutta"], calcutta.reload.alternative_names
        assert_equal "Kolkata", calcutta.name
        assert india.reload.present?
      end

      test "a rename that only changes case or punctuation adds no alternative name" do
        place = location("paris")
        decide(place, :rename, new_name: "Paris")

        Applier.call(run: "r1")

        assert_equal [], place.reload.alternative_names
      end

      test "a re-run with nothing pending still reconciles inherited links" do
        us = location("United States", links: 0)
        place = location("Chicago")
        place.update!(parent: us)
        decide(place, :keep)
        Applier.call(run: "r1")
        inherited = CategoryItem.find_by!(category: us, item: @book, source: :inherited)
        inherited.delete

        Applier.call(run: "r1")

        assert CategoryItem.exists?(category: us, item: @book, source: :inherited)
      end

      test "created parents roll back together when the parenting step fails" do
        chicago = location("Chicago")
        decide(chicago, :set_parent, parent_chain: ["Illinois", "United States"])
        ::Books::Category.any_instance.stubs(:update!).raises(ActiveRecord::StatementInvalid, "boom")

        assert_raises(ActiveRecord::StatementInvalid) { Applier.call(run: "r1") }

        assert_nil ::Books::Category.find_by(name: "Illinois")
        assert_nil ::Books::Category.find_by(name: "United States")
      end

      test "chain creation ignores set_parent decisions on non-locations and deleted categories" do
        subject = location("Topic", type: :subject)
        gone = location("Gone Place")
        decide(subject, :set_parent, parent_chain: ["Atlantis"])
        decide(gone, :set_parent, parent_chain: ["Lemuria"])
        gone.update_columns(deleted: true)

        result = Applier.call(run: "r1")

        assert_equal 0, result.data["created"]
        assert_nil ::Books::Category.find_by(name: "Atlantis")
        assert_nil ::Books::Category.find_by(name: "Lemuria")
      end

      test "a retype supersedes a set_parent on the same category" do
        place = location("Hope")
        retype = decide(place, :retype, new_category_type: ::Category.category_types["subject"])
        parent = decide(place, :set_parent, parent_chain: ["Anywhere"])
        location("Anywhere")

        Applier.call(run: "r1")

        assert retype.reload.applied?
        assert parent.reload.stale?
      end

      test "a retype and the rename that accompanies it both apply" do
        place = location("Hope")
        retype = decide(place, :retype, new_category_type: ::Category.category_types["subject"], decided_by: :ai, stage: "locations_head")
        rename = decide(place, :rename, new_name: "Hope (virtue)", decided_by: :ai, stage: "locations_head")

        Applier.call(run: "r1")

        assert_equal %w[applied applied], [retype, rename].map { |d| d.reload.status }
        place.reload
        assert_equal "Hope (virtue)", place.name
        assert place.subject?
      end

      test "failure messages carry the exception class" do
        gone = location("Gone Target")
        source = location("Source")
        failing = decide(source, :merge, target_category: gone)
        gone.update_columns(deleted: true)

        Applier.call(run: "r1")

        assert_match(/\ARuntimeError: /, failing.reload.error)
      end

      test "mutual merges with equal links keep the older category" do
        a = location("Alpha")
        b = location("Beta")
        [a, b].each { |category| category.update_column(:item_count, 7) }
        first = decide(a, :merge, target_category: b)
        second = decide(b, :merge, target_category: a)

        Applier.call(run: "r1")

        assert first.reload.stale?
        assert second.reload.applied?
        assert_equal a, b.reload.merged_into
        refute a.reload.deleted?
      end

      test "chained merges resolve through the canonical target" do
        a = location("Alpha")
        b = location("Beta")
        c = location("Gamma")
        decide(a, :merge, target_category: b)
        second = decide(c, :merge, target_category: a)

        Applier.call(run: "r1")

        assert second.reload.applied?
        assert_equal b, c.reload.merged_into
        assert CategoryItem.exists?(category: b, item: @book)
      end

      test "a merge that raises after moving links rolls back and the rest still apply" do
        target = location("Chicago", links: 0)
        source = location("Chicgo")
        other = location("paris")
        failing = decide(source, :merge, target_category: target)
        rename = decide(other, :rename, new_name: "Paris")
        ::Categories::AncestorReconciler.stubs(:call).raises(RuntimeError, "boom").then.returns(nil)

        Applier.call(run: "r1")

        assert failing.reload.failed?
        assert_match "boom", failing.error
        refute source.reload.deleted?
        assert_nil source.merged_into_id
        assert CategoryItem.exists?(category: source, item: @book)
        refute CategoryItem.exists?(category: target, item: @book)
        assert rename.reload.applied?
      end

      test "two renames of one category: the later applied rename is the expected name on a re-run" do
        place = location("Chicgo")
        first = decide(place, :rename, new_name: "Chicago")
        second = decide(place, :rename, new_name: "Chicago, IL", decided_by: :ai, stage: "locations_head")
        place.update!(name: "Chicago, IL")
        first.update!(status: :applied)
        second.update!(status: :applied)
        again = decide(place, :set_parent, parent_chain: ["Nowhere"])
        again.update!(category_snapshot: again.category_snapshot.merge("name" => "Chicgo"))

        Applier.call(run: "r1")

        refute again.reload.stale?
      end

      def genre(name, books: [])
        record = ::Books::Category.create!(name: name, category_type: :genre)
        books.each { |book| CategoryItem.create!(category: record, item: book) }
        record
      end

      test "a merging split gives each book only its assigned targets and merges the empty genre" do
        lotr = @book
        dune = books_books(:crime_and_punishment)
        sf = genre("Science Fiction")
        fantasy = genre("Fantasy")
        combined = genre("Science Fiction Fantasy", books: [lotr, dune])
        split = decide(combined, :split, stage: "genres", target_category: sf, extra_target_ids: [fantasy.id],
          split_assignments: {lotr.id.to_s => [fantasy.id], dune.id.to_s => [sf.id, fantasy.id]})

        result = Applier.call(run: "r1")

        assert_equal "applied", split.reload.status
        assert_equal 1, result.data["split"]
        assert_equal sf, combined.reload.merged_into
        assert combined.deleted?
        refute CategoryItem.exists?(category: sf, item: lotr)
        assert CategoryItem.exists?(category: fantasy, item: lotr)
        assert CategoryItem.exists?(category: sf, item: dune)
        assert CategoryItem.exists?(category: fantasy, item: dune)
        assert_equal 0, CategoryItem.where(category: combined).count
        assert_equal 1, sf.reload.item_count
        assert_equal 2, fantasy.reload.item_count
      end

      test "a book missing from the assignments gets every target" do
        sf = genre("Science Fiction")
        fantasy = genre("Fantasy")
        combined = genre("Science Fiction Fantasy", books: [@book])
        decide(combined, :split, stage: "genres", target_category: sf, extra_target_ids: [fantasy.id])

        Applier.call(run: "r1")

        assert CategoryItem.exists?(category: sf, item: @book)
        assert CategoryItem.exists?(category: fantasy, item: @book)
      end

      test "a renaming split keeps the genre for its assigned books and drops it for the rest" do
        history_book = @book
        politics_book = books_books(:crime_and_punishment)
        politics = ::Books::Category.create!(name: "Politics", category_type: :subject)
        combined = genre("History and Politics", books: [history_book, politics_book])
        decide(combined, :split, stage: "genres", new_name: "History", extra_target_ids: [politics.id],
          split_assignments: {history_book.id.to_s => [combined.id], politics_book.id.to_s => [politics.id]})

        Applier.call(run: "r1")

        combined.reload
        assert_equal "History", combined.name
        refute combined.deleted?
        assert CategoryItem.exists?(category: combined, item: history_book)
        refute CategoryItem.exists?(category: combined, item: politics_book)
        assert CategoryItem.exists?(category: politics, item: politics_book)
        refute CategoryItem.exists?(category: politics, item: history_book)
      end

      test "a book answered with a non-primary target only ends off the primary in both split modes" do
        lotr = @book
        dune = books_books(:crime_and_punishment)

        # Merging mode: the primary is a different, existing category.
        sf = genre("Science Fiction")
        fantasy = genre("Fantasy")
        merging = genre("Science Fiction Fantasy", books: [lotr, dune])
        decide(merging, :split, stage: "genres", target_category: sf, extra_target_ids: [fantasy.id],
          split_assignments: {lotr.id.to_s => [fantasy.id], dune.id.to_s => [sf.id]})

        # Renaming mode: the category itself is the primary.
        other_fantasy = genre("High Fantasy")
        renaming = genre("Science Fiction and Fantasy Mix", books: [lotr, dune])
        decide(renaming, :split, stage: "genres", new_name: "Space Opera", extra_target_ids: [other_fantasy.id],
          split_assignments: {lotr.id.to_s => [other_fantasy.id], dune.id.to_s => [renaming.id]})

        Applier.call(run: "r1")

        refute CategoryItem.exists?(category: sf, item: lotr)
        assert CategoryItem.exists?(category: fantasy, item: lotr)
        assert CategoryItem.exists?(category: sf, item: dune)
        refute CategoryItem.exists?(category: fantasy, item: dune)

        refute CategoryItem.exists?(category: renaming, item: lotr)
        assert CategoryItem.exists?(category: other_fantasy, item: lotr)
        assert CategoryItem.exists?(category: renaming, item: dune)
        refute CategoryItem.exists?(category: other_fantasy, item: dune)
        refute renaming.reload.deleted?
      end

      test "a split keeps the source of each link and does not duplicate existing links" do
        sf = genre("Science Fiction", books: [@book])
        fantasy = genre("Fantasy")
        combined = ::Books::Category.create!(name: "Science Fiction Fantasy", category_type: :genre)
        CategoryItem.create!(category: combined, item: @book, source: :admin)
        decide(combined, :split, stage: "genres", target_category: sf, extra_target_ids: [fantasy.id])

        Applier.call(run: "r1")

        assert_equal 1, CategoryItem.where(category: sf, item: @book).count
        assert CategoryItem.exists?(category: fantasy, item: @book, source: :admin)
      end

      test "a keep with extra targets links the genre's books to them; a re-run adds nothing" do
        romance = genre("Romance")
        fantasy = genre("Fantasy")
        romantasy = genre("Romantasy", books: [@book])
        keep = decide(romantasy, :keep, stage: "genres", extra_target_ids: [romance.id, fantasy.id])

        Applier.call(run: "r1")
        Applier.call(run: "r1")

        assert_equal "applied", keep.reload.status
        assert_equal 1, CategoryItem.where(category: romance, item: @book).count
        assert_equal 1, CategoryItem.where(category: fantasy, item: @book).count
      end

      test "a rename with extra targets renames and links" do
        romance = genre("Romance")
        rom_com = genre("romcom", books: [@book])
        decide(rom_com, :rename, stage: "genres", new_name: "Romantic Comedy", extra_target_ids: [romance.id])

        Applier.call(run: "r1")

        assert_equal "Romantic Comedy", rom_com.reload.name
        assert CategoryItem.exists?(category: romance, item: @book)
      end

      test "a split is terminal: a keep on the same category goes stale" do
        sf = genre("Science Fiction")
        combined = genre("Science Fiction Fantasy", books: [@book])
        split = decide(combined, :split, stage: "genres", target_category: sf)
        keep = decide(combined, :keep, stage: "genres")

        Applier.call(run: "r1")

        assert_equal %w[applied stale], [split, keep].map { |d| d.reload.status }
      end

      def assert_failed_and_unchanged(decision, *categories, matching: nil)
        before = categories.map { |c| [c.reload.deleted, c.merged_into_id, CategoryItem.where(category: c).pluck(:item_id).sort] }
        Applier.call(run: "r1")
        assert_equal "failed", decision.reload.status
        assert_match matching, decision.error if matching
        assert_equal before, categories.map { |c| [c.reload.deleted, c.merged_into_id, CategoryItem.where(category: c).pluck(:item_id).sort] }
      end

      test "a split fails when its merging primary was merged away since the plan" do
        sf = genre("Science Fiction")
        elsewhere = genre("Sci-Fi")
        fantasy = genre("Fantasy")
        sf.update_columns(deleted: true, merged_into_id: elsewhere.id)
        combined = genre("Science Fiction Fantasy", books: [@book])
        split = decide(combined, :split, stage: "genres", target_category: sf, extra_target_ids: [fantasy.id],
          split_assignments: {@book.id.to_s => [sf.id]})

        assert_failed_and_unchanged(split, combined, elsewhere, fantasy, matching: /deleted or merged/)
      end

      test "a split fails when an extra target is deleted" do
        sf = genre("Science Fiction")
        fantasy = genre("Fantasy")
        fantasy.update_columns(deleted: true)
        combined = genre("Science Fiction Fantasy", books: [@book])
        split = decide(combined, :split, stage: "genres", target_category: sf, extra_target_ids: [fantasy.id])

        assert_failed_and_unchanged(split, combined, sf, fantasy, matching: /deleted or merged/)
      end

      test "a split fails when an assignment names an id outside its targets" do
        sf = genre("Science Fiction")
        fantasy = genre("Fantasy")
        stray = genre("Horror")
        combined = genre("Science Fiction Fantasy", books: [@book])
        split = decide(combined, :split, stage: "genres", target_category: sf, extra_target_ids: [fantasy.id],
          split_assignments: {@book.id.to_s => [stray.id]})

        assert_failed_and_unchanged(split, combined, sf, fantasy, stray, matching: /not a target/)
      end

      test "a split fails when an assignment is null rather than a list" do
        sf = genre("Science Fiction")
        fantasy = genre("Fantasy")
        combined = genre("Science Fiction Fantasy", books: [@book])
        split = decide(combined, :split, stage: "genres", target_category: sf, extra_target_ids: [fantasy.id],
          split_assignments: {@book.id.to_s => nil})

        assert_failed_and_unchanged(split, combined, sf, fantasy, matching: /not a list/)
      end

      test "a keep with a deleted extra target fails and links nothing" do
        gone = genre("Gone")
        gone.update_columns(deleted: true)
        romantasy = genre("Romantasy", books: [@book])
        keep = decide(romantasy, :keep, stage: "genres", extra_target_ids: [gone.id])

        assert_failed_and_unchanged(keep, romantasy, gone, matching: /deleted or merged/)
      end

      test "a split and a keep with extra targets on a protected category fail and change nothing" do
        sf = genre("Science Fiction")
        fantasy = genre("Fantasy")
        fiction = genre("Fiction", books: [@book])
        nonfiction = genre("Nonfiction", books: [@book])
        ::Books::Category.stubs(:protected_ids).returns([fiction.id, nonfiction.id])
        split = decide(fiction, :split, stage: "genres", target_category: sf, extra_target_ids: [fantasy.id])
        keep = decide(nonfiction, :keep, stage: "genres", extra_target_ids: [fantasy.id])

        Applier.call(run: "r1")

        assert_equal %w[failed failed], [split, keep].map { |d| d.reload.status }
        assert_match "protected", split.error
        assert_match "protected", keep.error
        assert_equal [[], [], [@book.id], [@book.id]], [sf, fantasy, fiction, nonfiction].map { |c| CategoryItem.where(category: c).pluck(:item_id) }
        refute fiction.reload.deleted?
      end

      test "a keep with extra targets leaves an existing link to the extra target alone" do
        fantasy = genre("Fantasy")
        romance = genre("Romance")
        romantasy = genre("Romantasy")
        CategoryItem.create!(category: romantasy, item: @book, source: :legacy)
        CategoryItem.create!(category: fantasy, item: @book, source: :admin)
        keep = decide(romantasy, :keep, stage: "genres", extra_target_ids: [fantasy.id, romance.id])

        Applier.call(run: "r1")

        assert_equal "applied", keep.reload.status
        assert_equal 1, CategoryItem.where(category: fantasy, item: @book).count
        assert CategoryItem.exists?(category: fantasy, item: @book, source: :admin)
        assert CategoryItem.exists?(category: romance, item: @book, source: :legacy)
      end
    end
  end
end
