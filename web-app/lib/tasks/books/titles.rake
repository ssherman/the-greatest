namespace :books do
  namespace :titles do
    desc "One-off: join titles cut inside their brackets and take closing series or format notes off titles and " \
      "subtitles (Services::Books::Titles::RepairNotes). DRY_RUN=1 lists the changes and saves nothing."
    task repair_notes: :environment do
      dry_run = ENV["DRY_RUN"].present?
      result = Services::Books::Titles::RepairNotes.call(dry_run: dry_run)
      result.data[:changes].each do |change|
        puts "#{change[:id]}\t#{change[:from].compact.join(" || ")}\t=> #{change[:to].compact.join(" || ")}"
      end
      puts "#{dry_run ? "would change" : "changed"} #{result.data[:changed]} books"
    end
  end
end
