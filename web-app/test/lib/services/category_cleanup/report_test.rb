require "test_helper"

module Services
  module CategoryCleanup
    class ReportTest < ActiveSupport::TestCase
      setup do
        Rails.configuration.x.categories_cleanup.stubs(:head_min_links).returns(2)
        # Fixture locations would otherwise join the undecided-head and lookup lists.
        ::Books::Category.where(category_type: :location).update_all(deleted: true)
      end

      def decide(category, action, stage: "locations_head", **attrs)
        CategoryCleanupDecision.create!({category: category, run: "r1", stage: stage, action: action, decided_by: :ai,
                                         category_snapshot: CategoryCleanupDecision.snapshot_of(category)}.merge(attrs))
      end

      def place(name, links: 0, type: :location)
        record = ::Books::Category.create!(name: name, category_type: type)
        ::Books::Book.order(:id).limit(links).each { |book| CategoryItem.create!(category: record, item: book) }
        record
      end

      def report_text(run: "r1")
        Report.call(run: run, out_dir: Dir.mktmpdir).data[:lines].join("\n")
      end

      def section(text, title)
        text[/^#{Regexp.escape(title)}:\n(.*?)(?=\n\n|\z)/m, 1].to_s
      end

      test "summarises counts, merges, created parents, roots, ambiguous names and failures, and writes a CSV" do
        target = place("Washington, D.C.")
        source = place("Washington DC")
        chicago = place("Chicago")
        europe = place("Europe")
        georgia = place("Georgia")
        source.update_columns(item_count: 40)
        decide(source, :merge, target_category: target, category_snapshot: CategoryCleanupDecision.snapshot_of(source.reload))
        decide(chicago, :set_parent, parent_chain: ["Illinois", "United States"])
        decide(europe, :keep, place_kind: "continent")
        decide(georgia, :keep, ambiguous: true)
        decide(chicago, :merge, status: :failed, error: "merge_into \"Atlantis\" matches no location", target_category: target)

        result = Report.call(run: "r1", out_dir: Dir.mktmpdir)
        text = result.data[:lines].join("\n")

        assert_includes text, "Washington DC (40) -> Washington, D.C."
        assert_includes text, "Illinois"
        assert_includes text, "Europe (continent)"
        assert_includes text, "Georgia"
        assert_includes text, "Atlantis"
        assert File.exist?(result.data[:csv_path])
        assert_equal 6, CSV.read(result.data[:csv_path]).size
      end

      test "undecided head-tier categories are listed per type, with none when all are decided" do
        undecided = place("Kilwa", links: 2)
        decided = place("Orapa", links: 2)
        place("Tiny", links: 1)
        decide(decided, :keep)

        listed = section(report_text, "Undecided head-tier categories")

        assert_includes listed, "location: 1"
        assert_includes listed, undecided.name
        assert_not_includes listed, "Orapa"
        assert_not_includes listed, "Tiny"

        decide(undecided, :keep, stage: "locations_tail")
        assert_includes section(report_text, "Undecided head-tier categories"), "(none)"
      end

      test "locations apply would create carry their slug, and flag slugs already taken" do
        free = place("Kilwa")
        other = place("Springfield")
        place("Gone Place").update_columns(deleted: true, slug: "narnia")
        ::Books::Category.where(name: "Springfield").update_all(slug: "springfield-prime")
        decide(free, :set_parent, parent_chain: ["Zanzibar Archipelago", "Narnia"])
        decide(other, :set_parent, parent_chain: ["Springfield Prime"])

        listed = section(report_text, "Locations apply would create")

        assert_includes listed, "Zanzibar Archipelago [zanzibar-archipelago]"
        assert_not_includes listed, "Zanzibar Archipelago [zanzibar-archipelago] (slug taken"
        assert_includes listed, "Narnia [narnia] (slug taken"
        assert_includes listed, "Springfield Prime [springfield-prime] (slug taken"
      end

      test "a slug held only by friendly_id history counts as taken" do
        child = place("Kilwa")
        FriendlyId::Slug.create!(slug: "old-town", sluggable_id: child.id, sluggable_type: "Category", scope: "Books::Category")
        decide(child, :set_parent, parent_chain: ["Old Town"])

        assert_includes section(report_text, "Locations apply would create"), "Old Town [old-town] (slug taken"
      end

      test "locations apply would create skips names without a comparison key" do
        child = place("Kilwa")
        decide(child, :set_parent, parent_chain: ["???", "Tanzania"])

        listed = section(report_text, "Locations apply would create")

        assert_includes listed, "Tanzania"
        assert_not_includes listed, "???"
      end

      test "merges into a category with its own pending terminal decision are listed" do
        a = place("Alpha")
        b = place("Beta")
        c = place("Gamma")
        d = place("Delta")
        decide(a, :merge, target_category: b)
        decide(b, :merge, target_category: c)
        decide(d, :merge, target_category: c)

        listed = section(report_text, "Merges into a category with its own pending terminal decision")

        assert_includes listed, "Alpha -> Beta"
        assert_not_includes listed, "Beta -> Gamma"
        assert_not_includes listed, "Delta"
      end

      test "proposed roots include renamed roots and exclude parented or terminal places" do
        renamed = place("Frnace")
        parented = place("Lyon")
        merged = place("Parys")
        decide(renamed, :rename, new_name: "France", place_kind: "country")
        decide(parented, :rename, new_name: "Lyon, France", place_kind: "city")
        decide(parented, :set_parent, parent_chain: ["France"])
        decide(merged, :keep, place_kind: "city")
        decide(merged, :merge, target_category: renamed)

        roots = section(report_text, "Proposed roots")

        assert_includes roots, "Frnace (country)"
        refute_includes roots, "Lyon"
        refute_includes roots, "Parys"
      end

      test "largest deletes list proposed deletes by link count" do
        big = place("Big Junk")
        small = place("Small Junk")
        big.update_columns(item_count: 900)
        small.update_columns(item_count: 3)
        decide(small, :delete, category_snapshot: CategoryCleanupDecision.snapshot_of(small.reload))
        decide(big, :delete, category_snapshot: CategoryCleanupDecision.snapshot_of(big.reload))

        lines = section(report_text, "Largest deletes (links lost)").lines.map(&:strip)

        assert_equal ["Big Junk (900)", "Small Junk (3)"], lines
      end

      test "the three new sections say none when empty" do
        text = report_text

        assert_includes section(text, "Locations apply would create"), "(none)"
        assert_includes section(text, "Merges into a category with its own pending terminal decision"), "(none)"
        assert_includes section(text, "Undecided head-tier categories"), "(none)"
      end
    end
  end
end
