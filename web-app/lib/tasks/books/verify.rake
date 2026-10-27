# frozen_string_literal: true

namespace :books do
  desc "Book verification pass: queue one run over <count> books or all; flags: post_import, unranked, retry_unsure, recheck, reharvest, second_chance"
  task :verify, [:limit] => :environment do |_task, args|
    flags = args.extras
    usage = "usage: books:verify[<count>|all(,#{Services::Books::Verification::Run::FLAGS.join("|")})...]"
    limit = case args[:limit]
    when "all" then nil
    when /\A[1-9]\d*\z/ then args[:limit].to_i
    else abort usage
    end
    abort usage unless (flags - Services::Books::Verification::Run::FLAGS).empty?
    abort "books:verify takes no redo: a redo names its books (books:verify_keep_bigger)" if flags.include?("redo")

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

    # A row a second chance settled goes back to what it was before the second
    # chance (unsure or removed), not all the way to before the first pass.
    if Services::Books::Verification::RevertSecondChance.applies_to?(Books::Verification.find_by(book: book))
      result = Services::Books::Verification::RevertSecondChance.call(book: book)
      abort result.errors.join("; ") unless result.success?

      next puts "reverted the second chance on book #{book.id}: back to #{result.data[:row].work_outcome}; " \
        "#{result.data[:skipped]} identifiers had moved and were skipped"
    end

    result = Services::Books::Verification::Revert.call(book: book)
    abort result.errors.join("; ") unless result.success?

    puts "reverted book #{book.id}: work keys back to #{result.data[:row].old_keys.inspect}; " \
      "#{result.data[:skipped]} identifiers had moved and were skipped"
  end

  desc "Verification pass: revert every book a second-chance route settled: " \
    "books:verify_revert_route[<resolve_candidate|exact_title|held_key|worldcat_isbns|second_chance_matcher>]; " \
    "second_chance_matcher is the books a second_chance run settled through Open Library's matcher"
  task :verify_revert_route, [:lookup] => :environment do |_task, args|
    routes = Services::Books::Verification::RevertSecondChance::REVERTIBLE_ROUTES
    abort "usage: books:verify_revert_route[#{routes.join("|")}] -- unknown value #{args[:lookup].inspect}" unless routes.include?(args[:lookup])

    counts = Services::Books::Verification::RevertSecondChance.route(args[:lookup])
    puts "route #{args[:lookup]}: reverted #{counts[:reverted]}, failed #{counts[:failed]}"
  end

  desc "Verification pass: books Open Library's matcher moved off a held work that passes our check onto one with fewer editions; " \
    "books:verify_keep_bigger lists them, books:verify_keep_bigger[apply] reverts them and queues a redo run"
  task :verify_keep_bigger, [:mode] => :environment do |_task, args|
    abort "usage: books:verify_keep_bigger[apply] -- unknown value #{args[:mode].inspect}" unless [nil, "apply"].include?(args[:mode])

    apply = args[:mode] == "apply"
    data = Services::Books::Verification::KeepBiggerWork.call(apply: apply).data
    puts "keep bigger work (#{apply ? "applied" : "dry run"}): #{data[:found]} books" \
      "#{", reverted #{data[:reverted]}, failed #{data[:failed].size}" if apply}"
    data[:failed].each { |line| puts "  failed: #{line}" }
    puts "samples:" if data[:samples].any?
    data[:samples].each { |line| puts "  #{line}" }
    puts "queued redo run #{data[:run_id]} over #{data[:reverted]} books. Progress: bin/rails books:verify_report" if data[:run_id]
  end
end
