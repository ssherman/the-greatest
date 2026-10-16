# frozen_string_literal: true

namespace :books do
  desc "Verification pass: queue one run over <count> books (ranked first) or all; add ,retry_unsure to retry unsure books from an older Open Library version"
  task :verify, [:limit, :mode] => :environment do |_task, args|
    usage = "usage: books:verify[<count>|all] or books:verify[<count>|all,retry_unsure]"
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
    Books::VerificationJob.perform_async(limit, run_id, retry_unsure)
    puts "queued verification run #{run_id}: #{limit || "all"} books#{" (retrying unsure books)" if retry_unsure}. " \
      "Only one run works at a time: one started while another is in progress exits at once, so queue it again later. " \
      "Progress: bin/rails books:verify_report"
  end

  desc "Verification pass: outcome counts, ranked coverage, the latest run, and the most recent replaced keys and pairs"
  task verify_report: :environment do
    puts Services::Books::Verification::Report.call
  end

  desc "Verification pass: put one book's keys back the way they were: books:verify_revert[<book id>]"
  task :verify_revert, [:book_id] => :environment do |_task, args|
    book = Books::Book.find_by(id: args[:book_id])
    abort "usage: books:verify_revert[<book id>] -- no book #{args[:book_id].inspect}" unless book

    result = Services::Books::Verification::Revert.call(book: book)
    abort result.errors.join("; ") unless result.success?

    puts "reverted book #{book.id}: work keys back to #{result.data.old_keys.inspect}"
  end
end
