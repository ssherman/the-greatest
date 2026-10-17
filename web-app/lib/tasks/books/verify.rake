# frozen_string_literal: true

namespace :books do
  desc "Book verification pass: queue one run over <count> books or all; flags: post_import, unranked, retry_unsure, recheck, reharvest"
  task :verify, [:limit] => :environment do |_task, args|
    flags = args.extras
    usage = "usage: books:verify[<count>|all(,#{Services::Books::Verification::Run::FLAGS.join("|")})...]"
    limit = case args[:limit]
    when "all" then nil
    when /\A[1-9]\d*\z/ then args[:limit].to_i
    else abort usage
    end
    abort usage unless (flags - Services::Books::Verification::Run::FLAGS).empty?

    run_id = SecureRandom.uuid
    Books::VerificationJob.perform_async(limit, run_id, flags)
    scope = flags.empty? ? "ranked, pre-import" : flags.join(", ")
    puts "queued verification run #{run_id}: #{limit || "all"} books (#{scope}). " \
      "Only one run works at a time: one started while another is in progress exits at once, so queue it again later. " \
      "Progress: bin/rails books:verify_report"
  end

  desc "Verification pass: stages, coverage, signals, the latest run, recent changes and random samples"
  task verify_report: :environment do
    puts Services::Books::Verification::Report.call(client: Books::OpenLibrary::Client.new)
  end

  desc "Verification pass: put one book's keys back the way they were: books:verify_revert[<book id>]"
  task :verify_revert, [:book_id] => :environment do |_task, args|
    book = Books::Book.find_by(id: args[:book_id])
    abort "usage: books:verify_revert[<book id>] -- no book #{args[:book_id].inspect}" unless book

    result = Services::Books::Verification::Revert.call(book: book)
    abort result.errors.join("; ") unless result.success?

    puts "reverted book #{book.id}: work keys back to #{result.data[:row].old_keys.inspect}; " \
      "#{result.data[:skipped]} identifiers had moved and were skipped"
  end
end
