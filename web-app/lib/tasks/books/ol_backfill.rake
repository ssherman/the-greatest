# frozen_string_literal: true

namespace :books do
  desc "Open Library key backfill: queue one run over <count> books (ranked first) or all; add ,retry_unsure to retry unsure books from an older Open Library version"
  task :ol_backfill, [:limit, :mode] => :environment do |_task, args|
    usage = "usage: books:ol_backfill[<count>|all] or books:ol_backfill[<count>|all,retry_unsure]"
    limit = case args[:limit]
    when "all" then nil
    when /\A[1-9]\d*\z/ then args[:limit].to_i
    else abort usage
    end
    retry_unsure = case args[:mode]
    when nil then false
    when "retry_unsure" then true
    else abort usage
    end

    run_id = SecureRandom.uuid
    Books::OpenLibraryBackfillJob.perform_async(limit, run_id, retry_unsure)
    puts "queued Open Library backfill run #{run_id}: #{limit || "all"} books#{" (retrying unsure books)" if retry_unsure}. " \
      "Only one run works at a time: one started while another is in progress exits at once, so queue it again later. " \
      "Progress: bin/rails books:ol_backfill_report"
  end

  desc "Open Library key backfill: outcome counts, ranked coverage, the latest run, and the most recent replaced keys and pairs"
  task ol_backfill_report: :environment do
    puts Services::Books::OlBackfill::Report.call
  end

  desc "Open Library key backfill: put one book's keys back the way they were: books:ol_backfill_revert[<book id>]"
  task :ol_backfill_revert, [:book_id] => :environment do |_task, args|
    book = Books::Book.find_by(id: args[:book_id])
    abort "usage: books:ol_backfill_revert[<book id>] -- no book #{args[:book_id].inspect}" unless book

    result = Services::Books::OlBackfill::Revert.call(book: book)
    abort result.errors.join("; ") unless result.success?

    puts "reverted book #{book.id}: work keys back to #{result.data.old_keys.inspect}"
  end
end
