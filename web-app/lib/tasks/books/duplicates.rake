# frozen_string_literal: true

namespace :books do
  desc "Duplicate sweep: enqueue one Books::FindDuplicatesJob per ranked book on the serial queue (optional limit)"
  task :find_duplicates, [:limit] => :environment do |_task, args|
    limit = args[:limit].presence&.to_i
    count = Books::FindDuplicatesJob.enqueue_ranked(limit: limit)
    puts "enqueued #{count} ranked books on the serial queue"
  end
end
