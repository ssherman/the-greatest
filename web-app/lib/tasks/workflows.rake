namespace :workflows do
  desc "List workflow steps that need attention: failed, or overdue by more than HOURS (default 6)"
  task :stuck, [:hours] => :environment do |_task, args|
    hours = (args[:hours].presence || 6).to_f
    rows = Workflows::Stuck.call(older_than: hours.hours)

    if rows.empty?
      puts "No stuck workflow steps."
    else
      rows.each do |row|
        puts [
          "run ##{row[:run_id]}", row[:workflow], row[:target], row[:step], row[:state],
          "since #{row[:since]&.utc&.iso8601 || "?"}", row[:error].to_s.squish.truncate(160).presence
        ].compact.join("  ")
      end
      puts "#{rows.size} stuck step#{"s" unless rows.size == 1}."
    end
  end
end
