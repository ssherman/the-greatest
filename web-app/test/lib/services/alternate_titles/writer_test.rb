require "test_helper"

module Services
  module AlternateTitles
    class WriterTest < ActiveSupport::TestCase
      setup do
        @book = books_books(:war_and_peace)
        @other = books_books(:crime_and_punishment)
        @user = users(:regular_user)
        ::AlternateTitle.where(titleable: [@book, @other]).delete_all
        @book.update_columns(alternate_titles: [])
        @other.update_columns(alternate_titles: [])
      end

      def row(book, title, status: :kept, source: :legacy, **attrs)
        ::AlternateTitle.create!(titleable: book, title: title, status: status, source: source, **attrs)
      end

      test "add creates rows with the source and assigns the copy" do
        result = Writer.add(record: @book, titles: ["Anna K"], source: :ai_enrichment)

        assert result.success?
        assert_equal ["Anna K"], result.data[:added]
        created = @book.alternate_title_records.find_by!(title: "Anna K")
        assert created.from_ai_enrichment?
        assert created.kept?
        assert_equal "Anna K", @book.alternate_titles.last
        assert @book.changed?
      end

      test "add backfills a book with no rows first" do
        @book.update_columns(alternate_titles: ["Voyna i mir"])
        @book.reload

        Writer.add(record: @book, titles: ["Guerre et paix"], source: :merge)

        assert_equal ["Voyna i mir", "Guerre et paix"], @book.alternate_titles
        assert @book.alternate_title_records.order(:id).first.from_legacy?
      end

      test "add skips a removed title" do
        removed = row(@book, "Capítulo 22", status: :removed)

        result = Writer.add(record: @book, titles: ["capítulo 22"], source: :legacy)

        assert removed.reload.removed?
        assert_equal ["capítulo 22"], result.data[:skipped_removed]
        assert_empty @book.alternate_titles
      end

      test "add reinstates a removed title for admin" do
        removed = row(@book, "Capítulo 22", status: :removed)

        result = Writer.add(record: @book, titles: ["capítulo 22"], source: :admin)

        removed.reload
        assert removed.kept?
        assert removed.from_admin?
        assert removed.decided_by_admin?
        assert_not_nil removed.decided_at
        assert_equal ["Capítulo 22"], result.data[:reinstated]
        assert_equal ["Capítulo 22"], @book.alternate_titles
      end

      test "add keeps the AI verdict when reinstating" do
        removed = row(@book, "Capítulo 22", status: :removed, verdict: :not_same_work, category: :junk, reason: "chapter")

        Writer.add(record: @book, titles: ["Capítulo 22"], source: :correction)

        removed.reload
        assert removed.from_correction?
        assert removed.decided_by_correction?
        assert_equal "chapter", removed.reason
        assert removed.verdict_not_same_work?
        assert removed.category_junk?
      end

      test "add skips the main title and existing rows" do
        row(@book, "Voyna i mir")

        result = Writer.add(record: @book, titles: ["War and Peace", "VOYNA I MIR", " ", nil, "Guerre"], source: :merge)

        assert_equal ["Guerre"], result.data[:added]
        assert_equal 2, @book.alternate_title_records.count
      end

      test "add dedupes incoming titles by normalized form" do
        result = Writer.add(record: @book, titles: ["Guerre", "GUERRE"], source: :merge)

        assert_equal ["Guerre"], result.data[:added]
      end

      test "replace removes titles left out" do
        row(@book, "A")
        b = row(@book, "B")

        result = Writer.replace(record: @book, titles: ["A"], source: :correction)

        b.reload
        assert b.removed?
        assert_equal "removed by correction", b.reason
        assert b.decided_by_correction?
        assert_not_nil b.decided_at
        assert_equal ["B"], result.data[:removed]
        assert_equal ["A"], @book.alternate_titles
      end

      test "replace records the user for admin" do
        b = row(@book, "B")

        Writer.replace(record: @book, titles: [], source: :admin, user: @user)

        assert_equal @user, b.reload.decided_by_user
        assert_equal "removed by admin", b.reason
      end

      test "replace keeps a comma title whole" do
        row(@book, "Good Night, Mr. Tom")

        result = Writer.replace(record: @book, titles: ["Good Night, Mr. Tom"], source: :admin)

        assert_empty result.data[:removed]
        assert_equal ["Good Night, Mr. Tom"], @book.alternate_titles
      end

      test "replace updates the spelling of a row matching by normalized form" do
        r = row(@book, "guerre et paix")

        Writer.replace(record: @book, titles: ["Guerre et Paix"], source: :admin)

        assert_equal "Guerre et Paix", r.reload.title
        assert_equal ["Guerre et Paix"], @book.alternate_titles
      end

      test "replace adds new titles and reinstates removed ones" do
        row(@book, "Old", status: :removed)

        result = Writer.replace(record: @book, titles: ["Old", "New"], source: :admin)

        assert_equal ["New"], result.data[:added]
        assert_equal ["Old"], result.data[:reinstated]
        assert_equal ["Old", "New"], @book.alternate_titles
      end

      test "replace rejects other sources" do
        assert_raises(ArgumentError) { Writer.replace(record: @book, titles: [], source: :legacy) }
      end

      test "decide removes and saves the book" do
        r = row(@book, "B")
        @book.update_columns(alternate_titles: ["B"])

        result = Writer.decide(row: r, status: :removed, user: @user)

        assert result.success?
        r.reload
        assert r.removed?
        assert r.decided_by_admin?
        assert_equal @user, r.decided_by_user
        assert_not_nil r.decided_at
        assert_equal "removed by admin", r.reason
        assert_empty @book.reload.alternate_titles
      end

      test "decide keeps the AI reason" do
        r = row(@book, "B", status: :removed, reason: "AI says chapter", verdict: :not_same_work, decided_by: :ai)

        Writer.decide(row: r, status: :kept, user: @user)

        r.reload
        assert r.kept?
        assert_equal "AI says chapter", r.reason
        assert_equal ["B"], @book.reload.alternate_titles
      end

      test "decide sets the admin reason when the row has none" do
        r = row(@book, "B")

        Writer.decide(row: r, status: :kept, user: @user)

        assert_equal "kept by admin", r.reload.reason
      end

      test "decide rejects other statuses" do
        assert_raises(ArgumentError) { Writer.decide(row: row(@book, "B"), status: :review) }
      end

      test "review rows stay in the copy" do
        row(@book, "Kept")
        row(@book, "Maybe", status: :review)
        row(@book, "Gone", status: :removed)

        Writer.add(record: @book, titles: ["New"], source: :merge)

        assert_equal ["Kept", "Maybe", "New"], @book.alternate_titles
        assert_equal ["Kept", "Maybe", "New"], Writer.listed_titles(@book)
      end

      test "move carries rows with status and verdicts" do
        row(@other, "Prestuplenie", status: :review, verdict: :same_work, reason: "ok")
        gone = row(@other, "Junk", status: :removed, verdict: :not_same_work, category: :junk)

        newly = Writer.move(source: @other, target: @book)

        assert_includes newly, "Prestuplenie"
        assert_includes newly, @other.title
        assert_not_includes newly, "Junk"
        gone.reload
        assert_equal @book.id, gone.titleable_id
        assert gone.removed?
        assert gone.verdict_not_same_work?
        assert gone.category_junk?
        assert_equal newly.sort, @book.alternate_titles.sort
        assert_equal 0, @other.alternate_title_records.count
      end

      test "move removed wins over kept when the source is removed" do
        row(@book, "Same")
        src = row(@other, "same", status: :removed, verdict: :not_same_work, category: :junk, reason: "bad", decided_by: :ai)

        Writer.move(source: @other, target: @book)

        t = @book.alternate_title_records.find_by!(normalized_title: "same")
        assert t.removed?
        assert_equal "bad", t.reason
        assert t.verdict_not_same_work?
        assert t.decided_by_ai?
        assert_not ::AlternateTitle.exists?(src.id)
        assert_not_includes @book.alternate_titles, "Same"
      end

      test "move removed wins over kept when the target is removed" do
        t = row(@book, "Same", status: :removed, reason: "mine")
        row(@other, "same")

        Writer.move(source: @other, target: @book)

        assert t.reload.removed?
        assert_equal "mine", t.reason
        assert_equal 1, @book.alternate_title_records.where(normalized_title: "same").count
        assert_not_includes @book.alternate_titles, "Same"
      end

      test "move does not readd a removed source title" do
        row(@book, @other.title, status: :removed)

        newly = Writer.move(source: @other, target: @book)

        assert_not_includes newly, @other.title
        assert @book.alternate_title_records.find_by!(title: @other.title).removed?
      end

      test "move drops a row equal to the target title" do
        row(@other, "war and peace")

        Writer.move(source: @other, target: @book)

        assert_not @book.alternate_title_records.exists?(normalized_title: "war and peace")
        assert_not_includes @book.alternate_titles, "war and peace"
      end

      test "move backfills both books first" do
        @other.update_columns(alternate_titles: ["Prestuplenie"])
        @other.reload

        newly = Writer.move(source: @other, target: @book)

        assert_includes newly, "Prestuplenie"
      end

      test "move survives a source whose array holds its own main title" do
        @other.update_columns(alternate_titles: [@other.title.upcase])
        @other.reload

        newly = Writer.move(source: @other, target: @book)

        assert_includes newly, @other.title.upcase
        assert_equal 1, @book.alternate_title_records.where(normalized_title: @other.title.downcase).count
      end

      test "add works after the caller preloaded the association" do
        @book.update_columns(alternate_titles: ["Voyna i mir"])
        @book.reload
        @book.alternate_title_records.to_a

        result = Writer.add(record: @book, titles: ["Voyna i mir", "Guerre"], source: :merge)

        assert_equal ["Guerre"], result.data[:added]
      end

      test "reinstating clears a generated removal reason but keeps an AI reason" do
        generated = row(@book, "Gen", status: :removed, reason: "removed by admin")
        ai = row(@book, "Ai", status: :removed, reason: "chapter title")

        Writer.add(record: @book, titles: ["Gen", "Ai"], source: :admin)

        assert_nil generated.reload.reason
        assert_equal "chapter title", ai.reload.reason
      end

      test "replace reinstating clears a generated removal reason" do
        generated = row(@book, "Gen", status: :removed, reason: "removed by correction")

        Writer.replace(record: @book, titles: ["Gen"], source: :correction)

        assert_nil generated.reload.reason
      end

      test "writer accepts a record without an array column" do
        album = music_albums(:dark_side_of_the_moon)
        assert_not album.has_attribute?(:alternate_titles)

        result = Writer.add(record: album, titles: ["The Dark Side", album.title], source: :admin)

        assert result.success?
        assert_equal ["The Dark Side"], result.data[:added]
        assert_equal ["The Dark Side"], Writer.listed_titles(album)
        row = ::AlternateTitle.find_by!(titleable: album)
        assert_equal "Music::Album", row.titleable_type
      end
    end
  end
end
