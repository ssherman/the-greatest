# frozen_string_literal: true

namespace :wikidata do
  desc "Re-check recent books and authors with no Wikidata match against the current local copy. Dry run unless APPLY=1"
  task recheck: :environment do
    version = ::Wikidata::Service.new.get("/version")
    abort "the service reported no dump_date" if version["dump_date"].blank?
    apply = ENV["APPLY"] == "1"
    result = Services::Wikidata::Recheck.call(dump_date: version["dump_date"], apply: apply)
    puts "dump #{version["dump_date"]}: #{result.data[:books]} books, #{result.data[:authors]} authors #{apply ? "queued" : "would be queued (dry run; APPLY=1 to queue)"}"
  end
end
