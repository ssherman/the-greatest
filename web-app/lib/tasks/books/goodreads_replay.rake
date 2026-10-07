# The legacy Goodreads replay (Goodreads import spec §12). A full pass, after
# every books migration pass and in the launch sequence:
#   load -> fix_slugs -> apply -> resolve (wait for the jobs) -> duplicates -> junk -> apply -> report
#   then finish_legacy, on the final launch pass only
# apply does nothing while config.x.goodreads_replay.auto_apply is false.
namespace :books do
  namespace :goodreads_replay do
    tally = ->(counts) { counts.map { |key, count| "#{key} #{count}" }.join(", ").presence || "nothing" }

    desc "Copy the legacy app's Goodreads imports, their uploads (legacy R2, LEGACY_R2_* env) and rows into " \
      "replay imports. Idempotent; reads the legacy_books database."
    task load: :environment do
      puts "legacy Goodreads imports: #{tally.call(Services::Books::GoodreadsReplay::LoadImports.call.data[:tally])}"
    end

    desc "Record a strip_identifier verdict for every slug-form Goodreads id (applied by books:goodreads_replay:apply)"
    task fix_slugs: :environment do
      puts "slug-form Goodreads ids: #{Services::Books::GoodreadsReplay::FixSlugIdentifiers.call.data[:recorded]} verdicts"
    end

    desc "Queue replay editions: pass one (fast sources) for rows without a finding, pass two (with Open Library " \
      "/resolve, on serial) for rows awaiting it. Re-run until both counts are 0."
    task resolve: :environment do
      counts = Books::GoodreadsReplay::ResolveEditionJob.enqueue_pending
      puts "queued #{counts[:first_pass]} editions for pass one and #{counts[:full_pass]} for the full pass"
    end

    desc "Record merge verdicts: one AI check per author name group, then the rule over pending book pairs. " \
      "Run after the resolve jobs finish."
    task duplicates: :environment do
      authors = Services::Books::GoodreadsReplay::FindAuthorDuplicates.call.data
      puts "author name groups: #{tally.call(authors[:tally])} (#{authors[:ai_calls]} AI calls)"
      puts "book pairs: #{Services::Books::GoodreadsReplay::FindBookDuplicates.call.data[:recorded]} merge verdicts"
    end

    desc "Record mark_provisional verdicts for authorless books and for books every holder is relinked away from"
    task junk: :environment do
      counts = Services::Books::GoodreadsReplay::FindJunk.call.data
      puts "mark_provisional verdicts: #{counts[:authorless]} authorless, #{counts[:orphaned]} with no support after relinks"
    end

    desc "Finish the legacy imports that failed or never finished (spec §12.8) as member imports, for admin " \
      "approval. Run after load. Optional limit; IDS=\"73 285\" picks legacy imports; DRY_RUN=1 starts nothing."
    task :finish_legacy, [:limit] => :environment do |_task, args|
      ids = ENV["IDS"].to_s.split(/[\s,]+/).reject(&:blank?).map(&:to_i).presence
      result = Services::Books::GoodreadsReplay::FinishLegacyImports.call(
        limit: args[:limit].presence&.to_i, ids: ids, dry_run: ENV["DRY_RUN"].present?
      )
      result.data[:outcomes].each { |id, outcome| puts "legacy import #{id}: #{outcome}" }
      puts "legacy imports to finish: #{tally.call(result.data[:tally])}"
    end

    desc "Apply every approved replay verdict (author merges, book merges, relinks, identifier strips, provisional). " \
      "Refuses while config.x.goodreads_replay.auto_apply is false. Idempotent; re-run after every books migration pass."
    task apply: :environment do
      result = Services::Books::GoodreadsReplay::ApplyVerdicts.call
      abort result.errors.join("; ") unless result.success?

      puts "applied verdicts: #{tally.call(result.data[:tally])}; " \
        "ranking recalculations queued: #{result.data[:ranking_configuration_ids].size}"
    end

    desc "Write the replay report (spec §12.9) to a path, or print it. " \
      "Usage: books:goodreads_replay:report[../docs/data-quality/goodreads-replay.md]"
    task :report, [:path] => :environment do |_task, args|
      markdown = Services::Books::GoodreadsReplay::Report.call.data[:markdown]
      if args[:path].present?
        File.write(args[:path], markdown)
        puts "wrote #{args[:path]}"
      else
        puts markdown
      end
    end

    desc "Print a random sample of auto-approved verdicts to hand-check before switching auto_apply on. " \
      "Usage: books:goodreads_replay:sample[kind,count] (count defaults to 50)"
    task :sample, [:kind, :count] => :environment do |_task, args|
      kinds = Books::RepairVerdict.kinds.keys
      abort "usage: books:goodreads_replay:sample[kind,count] with kind one of #{kinds.join(", ")}" unless kinds.include?(args[:kind])

      puts Services::Books::GoodreadsReplay::Report.sample(kind: args[:kind], count: (args[:count].presence || 50).to_i)
    end
  end
end
