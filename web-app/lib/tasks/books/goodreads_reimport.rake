# The Goodreads re-import (docs/superpowers/specs/2026-11-02-goodreads-reimport-design.md): re-matches every
# legacy-replayed CSV row to its exact book and puts each reader's entries there. Every task here only queues a job
# or prints; the work runs in Sidekiq. Order, and why: archive_mixed, match, (review the proposals), apply, decide,
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

    desc "Read-only: counts, what is stuck, samples and the acceptance queries (works with the gate off)"
    task report: :environment do
      puts Services::Books::GoodreadsReimport::Report.call
    end

    desc "Read-only: record each affected user's list item and review counts in tmp/goodreads_reimport_counts.json. Run before apply"
    task snapshot: :environment do
      puts "recorded the counts of #{Services::Books::GoodreadsReimport::Report.snapshot} users in #{Services::Books::GoodreadsReimport::Report::SNAPSHOT_PATH}"
    end

    desc "Queue the independent AI sample check (read-only); the job logs its result"
    task sample: :environment do
      Books::GoodreadsReimport::SampleJob.perform_async
      puts "queued the sample check; its result is in the Sidekiq log"
    end
  end
end
