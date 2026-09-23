# frozen_string_literal: true

namespace :books do
  desc "Duplicate sweep: enqueue one Books::FindDuplicatesJob per ranked book on the serial queue (required: a count, or 'all')"
  task :find_duplicates, [:limit] => :environment do |_task, args|
    raw = args[:limit]
    limit = case raw
    when "all" then nil
    when /\A[1-9]\d*\z/ then raw.to_i
    else
      abort "usage: books:find_duplicates[<count>|all] — the serial queue is shared with Amazon enrichment; start small"
    end
    count = Books::FindDuplicatesJob.enqueue_ranked(limit: limit)
    puts "enqueued #{count} ranked books on the serial queue"
  end
end
