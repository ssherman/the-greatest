# The legacy Goodreads replay (Goodreads import spec §12). A full pass, after
# every books migration pass and in the launch sequence:
#   load -> fix_slugs -> apply -> resolve (wait for the jobs) -> duplicates -> junk -> apply -> report
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
  end
end
