namespace :categories do
  desc "Add missing inherited location links and remove orphaned ones, for every book (idempotent)"
  task reconcile_ancestors: :environment do
    result = ::Categories::AncestorReconciler.call
    puts "Inherited location links: #{result.data[:added]} added, #{result.data[:removed]} removed"
  end
end
