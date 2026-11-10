namespace :books do
  namespace :categories do
    desc "Write the reviewed genre and audience definitions from config/books/genre_plan.yml into " \
      "categories.description (blanks only). Dry run unless APPLY=1."
    task write_definitions: :environment do
      apply = ENV["APPLY"] == "1"
      data = ::Services::Books::Categories::Definitions.call(apply: apply).data
      data[:written].each { |name| puts "#{apply ? "wrote" : "would write"}: #{name}" }
      data[:kept].each { |row| puts "kept: #{row[:name]} (held #{row[:held].inspect}; plan #{row[:plan].inspect})" }
      data[:missing].each { |name| puts "missing: #{name}" }
      puts "Re-run with APPLY=1 to write." unless apply
    end
  end
end
