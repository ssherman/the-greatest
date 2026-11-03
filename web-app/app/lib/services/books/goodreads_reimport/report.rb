# frozen_string_literal: true

module Services
  module Books
    module GoodreadsReimport
      # Plain-text report of a re-import run for Shane to read between batches (re-import spec 6): counts and
      # samples of every verdict kind, what is stuck and why, and the acceptance queries, each of which should
      # print 0. Read-only; works with the re-import gate off.
      module Report
        module_function

        SAMPLE = 10
        SAMPLE_ROWS = 300
        SAMPLE_MIXED_BOOKS = 20
        ERRORS_SHOWN = 5
        # A volume mounted in web and worker, so it survives a deploy.
        STORAGE_DIR = "storage/goodreads_reimport"
        BATCH = 5_000
        KINDS = %w[reimport_mixed reimport_match reimport_row reimport_guess reimport_strip reimport_author].freeze

        def call
          lines = []
          counts(lines)
          lines << "" << "AI agreement: #{agreement}"
          proposed(lines)
          lines << "" << "guesses: #{verdicts.reimport_guess.count} (approved #{verdicts.reimport_guess.approved.count}, " \
            "applied #{verdicts.reimport_guess.where.not(applied_at: nil).count})"
          stuck(lines)
          errors(lines)
          samples(lines)
          acceptance(lines)
          lines.join("\n")
        end

        # Per-user counts of list items and reviews on books, for the users the re-import touches. Taken before
        # apply, read by the "users whose count dropped" acceptance query. Returns how many users it recorded, or nil
        # when a snapshot exists and replace is not set: one taken after apply would hide every loss.
        def snapshot(replace: false)
          path = snapshot_path
          return nil if path.exist? && !replace

          counts = user_counts(in_scope_user_ids)
          FileUtils.mkdir_p(path.dirname)
          File.write(path, JSON.generate({"taken_at" => Time.current.iso8601, "users" => counts}))
          counts.size
        end

        # An independent AI reviewer (SameWorkTask again, not the matcher's verdicts) is asked whether each
        # sampled row's final book is the CSV row's work. Lists every row it answers "no" to, or could not answer.
        def sample(n: SAMPLE_ROWS, mixed_books: SAMPLE_MIXED_BOOKS, task_class: ::Services::Ai::Tasks::Books::SameWorkTask)
          picked = verdicts.reimport_row.where.not(applied_at: nil).where("payload ->> 'superseded_by' IS NULL")
          chosen = picked.order(Arel.sql("random()")).limit(n).to_a
          former = verdicts.reimport_mixed.approved.where.not(applied_at: nil).order(Arel.sql("random()")).limit(mixed_books).to_a
          keys = former.flat_map { |mixed| Array(mixed.payload["row_keys"]).map { |import_id, row_number| "reimport:row:#{import_id}:#{row_number}" } }
          chosen |= picked.where(subject_key: keys).to_a

          wrong = []
          failed = []
          chosen.each do |verdict|
            answer = ask(verdict, task_class)
            if answer.nil? then failed << verdict.subject_key
            elsif answer.data[:book_id].nil? then wrong << "#{verdict.subject_key}: #{describe_row(verdict)}"
            end
          end
          lines = ["checked #{chosen.size} rows (#{n} random, plus the rows of #{former.size} former mixed books)",
            "answered no: #{wrong.size}"]
          wrong.each { |line| lines << "  #{line}" }
          lines << "could not be checked: #{failed.size}" if failed.any?
          failed.first(SAMPLE).each { |key| lines << "  #{key}" }
          lines.join("\n")
        end

        def storage_dir = Rails.root.join(STORAGE_DIR)

        def snapshot_path = storage_dir.join("counts.json")

        def report_path(time = Time.current) = storage_dir.join("report-#{time.utc.strftime("%Y%m%dT%H%M%SZ")}.md")

        def verdicts = ::Books::RepairVerdict.where(kind: KINDS).current

        def counts(lines)
          lines << "verdicts (current): #{verdicts.count}" << "by kind and status:"
          verdicts.group(:kind, :status).count.sort_by { |key, _| key.map(&:to_s) }.each do |(kind, status), count|
            lines << "  #{kind} #{status} #{count}"
          end
          lines << "re-import rows by action and status:"
          verdicts.reimport_row.group(Arel.sql("payload ->> 'action'"), :status).count.sort_by { |key, _| key.map(&:to_s) }.each do |(action, status), count|
            lines << "  #{action} #{status} #{count}"
          end
          lines << "applied: #{verdicts.where.not(applied_at: nil).count}"
        end

        # Matches approved without anyone looking, over every match. A low rate means the AI and the finder
        # disagree a lot and Shane is reviewing most of them.
        def agreement
          matches = verdicts.reimport_match
          total = matches.count
          auto = matches.approved.where(reviewed_at: nil).count
          rate = total.zero? ? "n/a" : "#{(100.0 * auto / total).round(1)}%"
          "#{auto} of #{total} matches auto-approved (#{rate})"
        end

        def proposed(lines)
          lines << "" << "proposed (waiting for Shane): #{verdicts.proposed.count}"
          verdicts.proposed.group(:kind).count.sort_by { |kind, _| kind.to_s }.each { |kind, count| lines << "  #{kind} #{count}" }
        end

        def stuck(lines)
          waiting = waiting_mixed_books
          lines << "" << "mixed books stuck waiting (rows with no current, non-rejected row verdict): #{waiting.size}"
          waiting.first(SAMPLE).each do |book_id, missing|
            lines << "  book ##{book_id}: #{missing.size} rows, e.g. #{missing.first(3).join(", ")}"
          end

          rejected = verdicts.reimport_match.rejected
          lines << "" << "rejected matches (their rows wait for Shane): #{rejected.count}"
          sample_of(rejected).each { |verdict| lines << "  #{verdict.subject_key}: #{verdict.payload.dig("facts", "full_title")}" }

          noops = verdicts.where("payload ? 'closed_reason'")
          lines << "" << "closed as final no-ops: #{noops.count}"
          noops.group(Arel.sql("payload ->> 'closed_reason'")).count.sort.each { |reason, count| lines << "  #{reason}: #{count}" }
          sample_of(noops).each { |verdict| lines << "  #{verdict.subject_key}: #{verdict.payload["closed_reason"]}" }

          orphans = verdicts.reimport_row.where("payload ->> 'action' = 'add' AND payload ->> 'from_book_id' IS NULL")
          lines << "" << "rows with no current book (added from the CSV alone): #{orphans.count}"
          sample_of(orphans).each { |verdict| lines << "  #{verdict.summary}" }
        end

        def errors(lines)
          failed = verdicts.where.not(error: nil)
          lines << "" << "verdicts with an error: #{failed.count}"
          failed.order(:id).limit(ERRORS_SHOWN).each { |verdict| lines << "  #{verdict.kind} #{verdict.subject_key}: #{verdict.error.to_s.lines.first.to_s.strip}" }
        end

        def samples(lines)
          KINDS.each do |kind|
            lines << "" << "#{kind} (sample of #{SAMPLE}):"
            sample_of(verdicts.where(kind: kind)).each { |verdict| lines << "  [#{verdict.status}] #{verdict.summary}" }
          end
        end

        def acceptance(lines)
          lines << "" << "acceptance (each should be 0):"
          mismatched = title_mismatches
          lines << "  rows whose book's title differs from the CSV title with no approved verdict explaining it: #{mismatched.size}"
          mismatched.first(SAMPLE).each { |line| lines << "    #{line}" }
          dropped = dropped_users
          if dropped.nil?
            lines << "  users whose list item or review count dropped: no snapshot (run books:goodreads_reimport:snapshot before apply)"
          else
            lines << "  users whose list item or review count dropped beyond the destroys recorded: #{dropped[:unexplained].size}"
            dropped[:unexplained].first(SAMPLE).each { |row| lines << "    #{drop_line(row)}" }
            lines << "  explained drops (destroyed by a collision the verdicts recorded; not a loss): #{dropped[:explained].size}"
            dropped[:explained].first(SAMPLE).each { |row| lines << "    #{drop_line(row)}" }
          end
          lines << "  mixed books still present: #{still_mixed.size}"
        end

        def sample_of(scope) = scope.order(Arel.sql("random()")).limit(SAMPLE)

        # [[book_id, [row keys without a usable verdict]]] for mixed verdicts whose book is still there.
        def waiting_mixed_books
          mixed = verdicts.reimport_mixed.approved.where(applied_at: nil).order(:id).to_a
          mixed.filter_map do |verdict|
            keys = Array(verdict.payload["row_keys"]).map { |import_id, row_number| "reimport:row:#{import_id}:#{row_number}" }
            have = ::Books::RepairVerdict.reimport_row.current.where.not(status: :rejected).where(subject_key: keys).pluck(:subject_key)
            missing = keys - have
            [verdict.payload["book_id"], missing] if missing.any?
          end
        end

        # Applied row verdicts whose destination does not carry the CSV row's title. A match the AI answered with
        # high confidence, or that an admin reviewed, explains a difference (translations, editions); an
        # unreviewed "create" does not.
        def title_mismatches
          found = []
          after = 0
          loop do
            batch = applied_rows_after(after)
            break if batch.empty?

            after = batch.last[0]
            titles = ::Books::Book.where(id: batch.map { |row| row[3] }.compact.uniq).pluck(:id, :title, :subtitle)
              .to_h { |id, title, subtitle| [id, [title, subtitle]] }
            # A destination merged away since is looked up once per batch, and the matches are loaded once per batch.
            (batch.filter_map { |row| row[3] }.uniq - titles.keys).each { |id| titles[id] = resolve(id) }
            suspects = batch.select do |_id, _key, csv_title, to_id, _edition_id|
              to_id && !(titles[to_id] && title_keys(titles[to_id]).include?(csv_key(csv_title)))
            end
            matches = approved_matches(suspects.map { |row| row[4] })
            suspects.each do |_id, key, csv_title, to_id, edition_id|
              next if explained?(matches[edition_id], to_id)

              found << "#{key}: CSV \"#{csv_title}\" -> book ##{to_id} \"#{titles[to_id]&.first}\""
            end
          end
          found
        end

        def applied_rows_after(after)
          ::Books::RepairVerdict.reimport_row.current.where.not(applied_at: nil).where("books_repair_verdicts.id > ?", after)
            .where("payload ->> 'superseded_by' IS NULL")
            .joins("JOIN books_goodreads_import_rows r ON r.import_id = (payload ->> 'import_id')::bigint AND r.row_number = (payload ->> 'row_number')::int")
            .order(:id).limit(BATCH)
            .pluck(:id, :subject_key, Arel.sql("r.raw ->> 'Title'"), Arel.sql("(payload ->> 'to_book_id')::bigint"),
              Arel.sql("(payload ->> 'goodreads_edition_id')::bigint"))
        end

        def resolve(book_id)
          book = ::Services::Books::GoodreadsReplay::Apply::MergedBook.call(book_id)
          [book.title, book.subtitle] if book
        end

        def csv_key(text)
          cleaned = ::Services::Books::GoodreadsRebuild::ExportFacts.clean_title(text.to_s.sub(::Services::Books::GoodreadsRebuild::ExportFacts::SERIES_SUFFIX, "").strip)
          ::Services::Books::Verification::Check.title_key(cleaned)
        end

        def title_keys(book)
          title, subtitle = book
          check = ::Services::Books::Verification::Check
          [check.title_key(title), check.title_key([title, subtitle.presence].compact.join(": "))]
        end

        def approved_matches(edition_ids)
          ::Books::RepairVerdict.reimport_match.current.approved
            .where(subject_key: edition_ids.uniq.map { |id| "reimport:edition:#{id}" })
            .index_by { |verdict| verdict.subject_key.delete_prefix("reimport:edition:").to_i }
        end

        def explained?(match, to_id)
          return false if match.nil?
          return false unless (match.payload["book_id"] || match.payload["created_book_id"]) == to_id

          match.reviewed_at.present? || (match.payload.dig("ai", "answer").present? && match.payload.dig("ai", "confidence") == "high")
        end

        # nil without a snapshot; otherwise {unexplained:, explained:}, each [[user_id, "items"|"reviews", before, now,
        # recorded destroys]]. Items and reviews are compared separately, so a gained item cannot hide a lost review.
        # A drop that applied verdicts recorded as a destroy (a collision with an entry already on the destination, a
        # mixed book's leftovers) is explained; anything beyond that is not.
        def dropped_users
          path = snapshot_path
          return nil unless path.exist?

          before = JSON.parse(path.read).fetch("users").transform_keys(&:to_i)
          now = user_counts(before.keys)
          destroyed = recorded_destroys(before.keys)
          result = {unexplained: [], explained: []}
          before.each do |user_id, was|
            %w[items reviews].each do |what|
              drop = was[what] - now.fetch(user_id)[what]
              next unless drop.positive?

              recorded = destroyed.fetch([user_id, what], 0)
              result[(drop > recorded) ? :unexplained : :explained] << [user_id, what, was[what], now.fetch(user_id)[what], recorded]
            end
          end
          result
        end

        def drop_line(row)
          user_id, what, was, now, recorded = row
          "user #{user_id} #{what}: #{was} -> #{now} (#{recorded} recorded destroys)"
        end

        # {[user_id, "items"|"reviews"] => count} from the trails applied verdicts keep of what they destroyed.
        def recorded_destroys(user_ids)
          wanted = user_ids.to_set
          totals = Hash.new(0)
          trailed = ::Books::RepairVerdict.where(kind: %w[reimport_row reimport_guess]).where.not(applied_at: nil)
            .where("jsonb_array_length(COALESCE(payload -> 'moved' -> 'destroyed_items', '[]'::jsonb)) > 0 OR " \
              "jsonb_array_length(COALESCE(payload -> 'moved' -> 'destroyed_reviews', '[]'::jsonb)) > 0")
          trailed.find_each do |verdict|
            user_id = verdict.payload["user_id"]
            next unless wanted.include?(user_id)

            totals[[user_id, "items"]] += Array(verdict.payload.dig("moved", "destroyed_items")).size
            totals[[user_id, "reviews"]] += Array(verdict.payload.dig("moved", "destroyed_reviews")).size
          end
          ::Books::RepairVerdict.reimport_mixed.where.not(applied_at: nil).where("payload ? 'deleted'").find_each do |verdict|
            Array(verdict.payload["deleted"]).each do |item|
              totals[[item["user_id"], "items"]] += 1 if wanted.include?(item["user_id"])
            end
          end
          totals
        end

        def in_scope_user_ids
          ::Books::GoodreadsImport.legacy_replay.complete.distinct.pluck(:user_id)
        end

        # {user_id => {"items" => n, "reviews" => n}} for every given user, zero when they have none.
        def user_counts(user_ids)
          items = ::UserListItem.where(listable_type: "Books::Book").joins(:user_list).where(user_lists: {user_id: user_ids})
            .group("user_lists.user_id").count
          reviews = ::Review.where(reviewable_type: "Books::Book", user_id: user_ids).group(:user_id).count
          user_ids.sort.to_h { |id| [id, {"items" => items.fetch(id, 0), "reviews" => reviews.fetch(id, 0)}] }
        end

        def still_mixed
          ::Books::Book.where(id: ::Services::Books::GoodreadsReimport::MixedBooks.ids.to_a).pluck(:id)
        end

        def ask(verdict, task_class)
          edition = ::Books::GoodreadsEdition.find_by(id: verdict.payload["goodreads_edition_id"])
          book = ::Services::Books::GoodreadsReplay::Apply::MergedBook.call(verdict.payload["to_book_id"])
          return nil unless edition && book

          answer = task_class.new(facts: EditionFacts.call(edition: edition), books: [book]).call
          answer.success? ? answer : nil
        rescue => e
          Rails.logger.error("re-import sample: #{verdict.subject_key} failed: #{e.class}: #{e.message}")
          nil
        end

        def describe_row(verdict)
          edition = ::Books::GoodreadsEdition.find_by(id: verdict.payload["goodreads_edition_id"])
          book = ::Services::Books::GoodreadsReplay::Apply::MergedBook.call(verdict.payload["to_book_id"])
          %(CSV "#{edition&.title}" by #{edition&.primary_author} -> book ##{book&.id} "#{book&.title}")
        end
      end
    end
  end
end
