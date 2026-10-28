# The Goodreads rebuild (docs/superpowers/specs/2026-10-27-goodreads-rebuild-design.md,
# docs/features/goodreads-rebuild.md): repairs the books legacy's Goodreads imports made, from the
# export rows. Steps and their order live in docs/launch-todo.md.
namespace :books do
  namespace :goodreads_rebuild do
    tally = ->(counts) { counts.map { |key, count| "#{key} #{count}" }.join(", ").presence || "nothing" }

    desc "Read-only: how many post-import books are trusted (on a real list) and how many are derived (import-made)"
    task cohorts: :environment do
      puts "post-import books: #{tally.call(Services::Books::GoodreadsRebuild::Cohort.counts)}"
    end

    desc "Queue the stage one survey (local only) over <count> derived books or all; add redo to re-survey surveyed books"
    task :survey, [:limit, :redo] => :environment do |_task, args|
      usage = "usage: books:goodreads_rebuild:survey[<count>|all(,redo)]"
      limit = case args[:limit]
      when "all" then nil
      when /\A[1-9]\d*\z/ then args[:limit].to_i
      else abort usage
      end
      abort usage unless [nil, "redo"].include?(args[:redo])

      resurvey = args[:redo] == "redo"
      Books::GoodreadsRebuild::SurveyJob.perform_async(limit, resurvey)
      puts "queued survey of #{limit || "all"} derived books#{" (redo)" if resurvey}"
    end

    desc "Survey pass 2: look up derived editions' ISBNs in WorldCat and Open Library with [threads] threads (default 4). " \
      "LOCAL services only: run on Shane's PC with OPEN_LIBRARY_SERVICE_URL and WORLDCAT_SERVICE_URL set to localhost. " \
      "Re-run to continue after a stop."
    task :gather_evidence, [:threads] => :environment do |_task, args|
      data = Services::Books::GoodreadsRebuild::EvidenceRun.call(threads: (args[:threads] || 4).to_i).data
      puts "looked up #{data[:looked_up]} editions#{" -- stopped: #{data[:error]}" if data[:stopped]}"
    end

    desc "Write the edition evidence to [path] (default tmp/rebuild_edition_evidence.jsonl.gz) for import in production"
    task :export_evidence, [:path] => :environment do |_task, args|
      path = args[:path] || "tmp/rebuild_edition_evidence.jsonl.gz"
      puts "exported #{Services::Books::GoodreadsRebuild::EvidenceTransfer.export(path)} evidence rows to #{path}"
    end

    desc "Upsert edition evidence from [path], a file export_evidence wrote. Safe to re-run"
    task :import_evidence, [:path] => :environment do |_task, args|
      abort "usage: books:goodreads_rebuild:import_evidence[<path>]" if args[:path].blank?

      puts "evidence: #{tally.call(Services::Books::GoodreadsRebuild::EvidenceTransfer.import(args[:path]))}"
    end

    desc "Read-only: the stage one survey's counts and samples"
    task survey_report: :environment do
      puts Services::Books::GoodreadsRebuild::SurveyReport.call
    end

    desc "Retire the replay's proposed relinks and identifier strips (rejected and superseded). " \
      "A dry run unless [apply]; a second apply finds 0."
    task :retire_replay_proposals, [:apply] => :environment do |_task, args|
      result = Services::Books::GoodreadsRebuild::RetireReplayProposals.call(apply: args[:apply] == "apply")
      puts "proposed replay verdicts: #{tally.call(result.data[:counts])}"
      puts(result.data[:applied] ? "retired" :
        "dry run: nothing changed; run books:goodreads_rebuild:retire_replay_proposals[apply]")
    end
  end
end
