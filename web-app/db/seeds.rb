# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).
#
# Example:
#
#   ["Action", "Comedy", "Drama", "Horror"].each do |genre_name|
#     MovieGenre.find_or_create_by!(name: genre_name)
#   end

# Seed Global Penalties
puts "Seeding Global Penalties..."

# Define penalties with their dynamic type mappings
penalty_definitions = [
  # Static penalties (no dynamic_type)
  {name: "List: Creator of the list, sells the items on the list", dynamic_type: nil},
  {name: "List: contains over 500 items(Quantity over Quality)", dynamic_type: nil},
  {name: "List: criteria is not just best/favorite", dynamic_type: nil},
  {name: "List: is a follow up/honorable mention to a different list", dynamic_type: nil},
  {name: "List: only covers 1 specific gender", dynamic_type: nil},
  {name: "List: only covers 1 specific language", dynamic_type: nil},
  {name: "List: only covers items with a weird criteria", dynamic_type: nil},
  {name: "Voters: are mostly from a single country/location", dynamic_type: nil},
  {name: "Voters: diversity of voters is very low", dynamic_type: nil},
  {name: "Voters: not critics, authors, or experts", dynamic_type: nil},
  {name: "Voters: restricted to a distinct criteria(race, gender, etc)", dynamic_type: nil},

  # Dynamic penalties (mapped to dynamic_types)
  {name: "Voters: Unknown Names", dynamic_type: :voter_names_unknown},
  {name: "Voters: Voter Count", dynamic_type: :number_of_voters},
  {name: "Voters: Unknown Count", dynamic_type: :voter_count_unknown},
  {name: "Voters: Estimated Count", dynamic_type: :voter_count_estimated},
  {name: "List: only covers 1 specific location", dynamic_type: :location_specific},
  {name: "List: only covers 1 specific genre", dynamic_type: :category_specific},
  {name: "List: number of years covered", dynamic_type: :num_years_covered}
]

# Create or find penalties
penalty_definitions.each do |penalty_def|
  penalty = Global::Penalty.find_or_create_by(
    name: penalty_def[:name],
    user_id: nil  # Global penalty
  ) do |p|
    p.dynamic_type = penalty_def[:dynamic_type]
    p.description = "System-wide penalty: #{penalty_def[:name]}"
  end

  puts "  #{penalty.persisted? ? "Found" : "Created"} penalty: #{penalty.name}"
end

puts "Global penalties seeding completed!"
puts "Total Global::Penalty records: #{Global::Penalty.count}"
