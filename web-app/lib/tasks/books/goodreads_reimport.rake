# The Goodreads re-import (docs/superpowers/specs/2026-11-02-goodreads-reimport-design.md): re-matches every
# legacy-replayed CSV row to its exact book and puts each reader's entries there. Every task here only queues a job
# or prints; the work runs in Sidekiq. Order, and why: link_legacy_books (after books:goodreads_replay:load; the
# survey and decide read legacy's book from it), archive_mixed, match, (review the proposals), apply, decide,
# snapshot, apply, check_authors, apply, report, sample. Decide waits for the matches to be applied, so apply runs
# once between match and decide.
namespace :books do
  namespace :goodreads_reimport do
    usage = ->(name) { "usage: books:goodreads_reimport:#{name}[<count>|all]" }

    gate = lambda do
      next if Rails.configuration.x.goodreads_reimport.enabled

      abort "the Goodreads re-import is off: set GOODREADS_REIMPORT_ENABLED=true (config.x.goodreads_reimport.enabled) on the server that runs Sidekiq"
    end

    limit = lambda do |name, value|
      case value
      when "all" then nil
      when /\A[1-9]\d*\z/ then value.to_i
      else abort usage.call(name)
      end
    end

    desc "Queue the record of legacy's book on replay rows that lack it; run after books:goodreads_replay:load, before the survey"
    task link_legacy_books: :environment do
      gate.call
      puts "queued #{Books::GoodreadsReimport::LinkLegacyBooksJob.enqueue} readers with unlinked rows " \
        "(the result is in the Sidekiq log: \"link_legacy_books batch\")"
    end

    desc "Queue the archive of every mixed book (verdicts only; nothing is deleted)"
    task archive_mixed: :environment do
      gate.call
      puts "reminder: refresh the survey first (books:goodreads_rebuild:survey[all,redo]); the mixed books are read from it"
      puts "queued the archive of #{Books::GoodreadsReimport::ArchiveMixedJob.enqueue} mixed books"
    end

    desc "Queue the edition match over <count> editions without one, or all"
    task :match, [:limit] => :environment do |_task, args|
      count = limit.call("match", args[:limit])
      gate.call
      puts "queued #{Books::GoodreadsReimport::MatchEditionsJob.enqueue(limit: count)} editions for matching"
    end

    desc "Queue a second match of <count> \"create a new book\" verdicts recorded before the English-title search, or all " \
      "(unreviewed and unapplied only)"
    task :recheck_creates, [:limit] => :environment do |_task, args|
      count = limit.call("recheck_creates", args[:limit])
      gate.call
      puts "queued #{Books::GoodreadsReimport::RecheckCreatesJob.enqueue(limit: count)} create verdicts for a second match"
    end

    desc "Queue the row decisions for <count> users without all rows decided, or all; also queues the guesses for mixed books"
    task :decide, [:limit] => :environment do |_task, args|
      count = limit.call("decide", args[:limit])
      gate.call
      puts "queued #{Books::GoodreadsReimport::DecideRowsJob.enqueue(limit: count)} users for row decisions"
      puts "queued #{Books::GoodreadsReimport::DecideGuessesJob.enqueue} mixed books for guesses " \
        "(a book whose rows are not all decided answers waiting; run decide again later)"
    end

    desc "Queue the apply of every approved re-import verdict (one chain at a time)"
    task apply: :environment do
      gate.call
      Books::GoodreadsReimport::ApplyJob.perform_async
      puts "queued the apply chain"
    end

    desc "Queue the author check over <count> destination books, or all"
    task :check_authors, [:limit] => :environment do |_task, args|
      count = limit.call("check_authors", args[:limit])
      gate.call
      puts "queued #{Books::GoodreadsReimport::CheckAuthorsJob.enqueue(limit: count)} books for the author check"
    end

    desc "Queue the report (read-only; works with the gate off). It is written to storage/goodreads_reimport/report-<UTC time>.md"
    task report: :environment do
      Books::GoodreadsReimport::ReportJob.perform_async
      puts "queued the report; it will be written under #{Services::Books::GoodreadsReimport::Report.storage_dir}/report-<UTC time>.md " \
        "(the path is in the Sidekiq log). Re-enqueue if a deploy interrupted it"
    end

    desc "Queue the snapshot of each affected user's list item and review counts (read-only). Run before apply. " \
      "It refuses to replace an existing snapshot; snapshot[redo] does (only before any apply moved rows); " \
      "snapshot[new_pass] writes a further counts-<UTC time>.json for a later pass and leaves the earlier files alone"
    task :snapshot, [:mode] => :environment do |_task, args|
      abort "usage: books:goodreads_reimport:snapshot[redo] or snapshot[new_pass]" unless [nil, "redo", "new_pass"].include?(args[:mode])

      report = Services::Books::GoodreadsReimport::Report
      Books::GoodreadsReimport::SnapshotJob.perform_async(args[:mode] == "redo", args[:mode] == "new_pass")
      # A new pass's file is named by the job when it runs, not now: only the pattern is known here.
      target = (args[:mode] == "new_pass") ? report.storage_dir.join("counts-<UTC time>.json") : report.snapshot_path
      puts "queued the snapshot; it will be written to #{target} " \
        "(left alone if it exists and redo was not given; the result is in the Sidekiq log). Re-enqueue if a deploy interrupted it"
    end

    desc "Queue the independent AI sample check (read-only); the job logs its result"
    task sample: :environment do
      Books::GoodreadsReimport::SampleJob.perform_async
      puts "queued the sample check; its result is in the Sidekiq log. Re-enqueue if a deploy interrupted it"
    end
  end
end
