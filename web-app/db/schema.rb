# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.0].define(version: 2025_08_23_054414) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "ai_chats", force: :cascade do |t|
    t.integer "chat_type", default: 0, null: false
    t.string "model", null: false
    t.integer "provider", default: 0, null: false
    t.decimal "temperature", precision: 3, scale: 2, default: "0.2", null: false
    t.boolean "json_mode", default: false, null: false
    t.jsonb "response_schema"
    t.jsonb "messages"
    t.jsonb "raw_responses"
    t.string "parent_type"
    t.bigint "parent_id"
    t.bigint "user_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["parent_type", "parent_id"], name: "index_ai_chats_on_parent"
    t.index ["user_id"], name: "index_ai_chats_on_user_id"
  end

  create_table "categories", force: :cascade do |t|
    t.string "type", null: false
    t.string "name", null: false
    t.string "slug"
    t.text "description"
    t.integer "category_type", default: 0
    t.integer "import_source"
    t.string "alternative_names", default: [], array: true
    t.integer "item_count", default: 0
    t.boolean "deleted", default: false
    t.bigint "parent_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["category_type"], name: "index_categories_on_category_type"
    t.index ["deleted"], name: "index_categories_on_deleted"
    t.index ["name"], name: "index_categories_on_name"
    t.index ["parent_id"], name: "index_categories_on_parent_id"
    t.index ["slug"], name: "index_categories_on_slug"
    t.index ["type", "slug"], name: "index_categories_on_type_and_slug"
    t.index ["type"], name: "index_categories_on_type"
  end

  create_table "category_items", force: :cascade do |t|
    t.bigint "category_id", null: false
    t.string "item_type", null: false
    t.bigint "item_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["category_id", "item_type", "item_id"], name: "index_category_items_on_category_id_and_item_type_and_item_id", unique: true
    t.index ["category_id"], name: "index_category_items_on_category_id"
    t.index ["item_type", "item_id"], name: "index_category_items_on_item"
    t.index ["item_type", "item_id"], name: "index_category_items_on_item_type_and_item_id"
  end

  create_table "friendly_id_slugs", force: :cascade do |t|
    t.string "slug", null: false
    t.integer "sluggable_id", null: false
    t.string "sluggable_type", limit: 50
    t.string "scope"
    t.datetime "created_at"
    t.index ["slug", "sluggable_type", "scope"], name: "index_friendly_id_slugs_on_slug_and_sluggable_type_and_scope", unique: true
    t.index ["slug", "sluggable_type"], name: "index_friendly_id_slugs_on_slug_and_sluggable_type"
    t.index ["sluggable_type", "sluggable_id"], name: "index_friendly_id_slugs_on_sluggable_type_and_sluggable_id"
  end

  create_table "identifiers", force: :cascade do |t|
    t.string "identifiable_type", null: false
    t.bigint "identifiable_id", null: false
    t.integer "identifier_type", null: false
    t.string "value", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["identifiable_type", "identifiable_id"], name: "index_identifiers_on_identifiable"
    t.index ["identifiable_type", "identifier_type", "value", "identifiable_id"], name: "index_identifiers_on_lookup_unique", unique: true
    t.index ["identifiable_type", "value"], name: "index_identifiers_on_type_and_value"
  end

  create_table "list_items", force: :cascade do |t|
    t.bigint "list_id", null: false
    t.string "listable_type", null: false
    t.bigint "listable_id", null: false
    t.integer "position"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["list_id", "listable_type", "listable_id"], name: "index_list_items_on_list_and_listable_unique", unique: true
    t.index ["list_id", "position"], name: "index_list_items_on_list_id_and_position"
    t.index ["list_id"], name: "index_list_items_on_list_id"
    t.index ["listable_type", "listable_id"], name: "index_list_items_on_listable"
  end

  create_table "list_penalties", force: :cascade do |t|
    t.bigint "list_id", null: false
    t.bigint "penalty_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["list_id", "penalty_id"], name: "index_list_penalties_on_list_and_penalty", unique: true
    t.index ["list_id"], name: "index_list_penalties_on_list_id"
    t.index ["penalty_id"], name: "index_list_penalties_on_penalty_id"
  end

  create_table "lists", force: :cascade do |t|
    t.string "type", null: false
    t.string "name", null: false
    t.text "description"
    t.string "source"
    t.string "url"
    t.integer "status", default: 0, null: false
    t.integer "estimated_quality", default: 0, null: false
    t.boolean "high_quality_source"
    t.boolean "category_specific"
    t.boolean "location_specific"
    t.integer "year_published"
    t.boolean "yearly_award"
    t.integer "number_of_voters"
    t.boolean "voter_count_unknown"
    t.boolean "voter_names_unknown"
    t.text "formatted_text"
    t.text "raw_html"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "submitted_by_id"
    t.index ["submitted_by_id"], name: "index_lists_on_submitted_by_id"
  end

  create_table "movies_credits", force: :cascade do |t|
    t.bigint "person_id", null: false
    t.string "creditable_type", null: false
    t.bigint "creditable_id", null: false
    t.integer "role", default: 0, null: false
    t.integer "position"
    t.string "character_name"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["creditable_type", "creditable_id"], name: "index_movies_credits_on_creditable"
    t.index ["creditable_type", "creditable_id"], name: "index_movies_credits_on_creditable_type_and_creditable_id"
    t.index ["person_id", "role"], name: "index_movies_credits_on_person_id_and_role"
    t.index ["person_id"], name: "index_movies_credits_on_person_id"
  end

  create_table "movies_movies", force: :cascade do |t|
    t.string "title", null: false
    t.string "slug", null: false
    t.text "description"
    t.integer "release_year"
    t.integer "runtime_minutes"
    t.integer "rating"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["rating"], name: "index_movies_movies_on_rating"
    t.index ["release_year"], name: "index_movies_movies_on_release_year"
    t.index ["slug"], name: "index_movies_movies_on_slug", unique: true
  end

  create_table "movies_people", force: :cascade do |t|
    t.string "name", null: false
    t.string "slug", null: false
    t.text "description"
    t.date "born_on"
    t.date "died_on"
    t.string "country", limit: 2
    t.integer "gender"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["gender"], name: "index_movies_people_on_gender"
    t.index ["slug"], name: "index_movies_people_on_slug", unique: true
  end

  create_table "movies_releases", force: :cascade do |t|
    t.bigint "movie_id", null: false
    t.string "release_name"
    t.integer "release_format", default: 0, null: false
    t.integer "runtime_minutes"
    t.date "release_date"
    t.jsonb "metadata"
    t.boolean "is_primary", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["is_primary"], name: "index_movies_releases_on_is_primary"
    t.index ["movie_id", "release_name", "release_format"], name: "index_movies_releases_on_movie_and_name_and_format", unique: true
    t.index ["movie_id"], name: "index_movies_releases_on_movie_id"
    t.index ["release_date"], name: "index_movies_releases_on_release_date"
    t.index ["release_format"], name: "index_movies_releases_on_release_format"
  end

  create_table "music_albums", force: :cascade do |t|
    t.string "title", null: false
    t.string "slug", null: false
    t.text "description"
    t.bigint "primary_artist_id", null: false
    t.integer "release_year"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["primary_artist_id"], name: "index_music_albums_on_primary_artist_id"
    t.index ["slug"], name: "index_music_albums_on_slug", unique: true
  end

  create_table "music_artists", force: :cascade do |t|
    t.string "name", null: false
    t.string "slug", null: false
    t.text "description"
    t.integer "kind", default: 0, null: false
    t.string "country", limit: 2
    t.date "born_on"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "year_died"
    t.integer "year_formed"
    t.integer "year_disbanded"
    t.index ["kind"], name: "index_music_artists_on_kind"
    t.index ["slug"], name: "index_music_artists_on_slug", unique: true
  end

  create_table "music_credits", force: :cascade do |t|
    t.bigint "artist_id", null: false
    t.string "creditable_type", null: false
    t.bigint "creditable_id", null: false
    t.integer "role", default: 0, null: false
    t.integer "position"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["artist_id", "role"], name: "index_music_credits_on_artist_id_and_role"
    t.index ["artist_id"], name: "index_music_credits_on_artist_id"
    t.index ["creditable_type", "creditable_id"], name: "index_music_credits_on_creditable"
    t.index ["creditable_type", "creditable_id"], name: "index_music_credits_on_creditable_type_and_creditable_id"
  end

  create_table "music_memberships", force: :cascade do |t|
    t.bigint "artist_id", null: false
    t.bigint "member_id", null: false
    t.date "joined_on"
    t.date "left_on"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["artist_id", "member_id", "joined_on"], name: "index_music_memberships_on_artist_member_joined", unique: true
    t.index ["artist_id"], name: "index_music_memberships_on_artist_id"
    t.index ["member_id"], name: "index_music_memberships_on_member_id"
  end

  create_table "music_releases", force: :cascade do |t|
    t.bigint "album_id", null: false
    t.string "release_name"
    t.integer "format", default: 0, null: false
    t.jsonb "metadata"
    t.date "release_date"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "country"
    t.integer "status", default: 0, null: false
    t.string "labels", default: [], array: true
    t.index ["album_id"], name: "index_music_releases_on_album_id"
    t.index ["country"], name: "index_music_releases_on_country"
    t.index ["status"], name: "index_music_releases_on_status"
  end

  create_table "music_song_relationships", force: :cascade do |t|
    t.bigint "song_id", null: false
    t.bigint "related_song_id", null: false
    t.integer "relation_type", default: 0, null: false
    t.bigint "source_release_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["related_song_id"], name: "index_music_song_relationships_on_related_song_id"
    t.index ["song_id", "related_song_id", "relation_type"], name: "index_music_song_relationships_on_song_related_type", unique: true
    t.index ["song_id"], name: "index_music_song_relationships_on_song_id"
    t.index ["source_release_id"], name: "index_music_song_relationships_on_source_release_id"
  end

  create_table "music_songs", force: :cascade do |t|
    t.string "title", null: false
    t.string "slug", null: false
    t.text "description"
    t.integer "duration_secs"
    t.integer "release_year"
    t.string "isrc", limit: 12
    t.text "lyrics"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "notes"
    t.index ["isrc"], name: "index_music_songs_on_isrc", unique: true, where: "(isrc IS NOT NULL)"
    t.index ["slug"], name: "index_music_songs_on_slug", unique: true
  end

  create_table "music_tracks", force: :cascade do |t|
    t.bigint "release_id", null: false
    t.bigint "song_id", null: false
    t.integer "medium_number", default: 1, null: false
    t.integer "position", null: false
    t.integer "length_secs"
    t.text "notes"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["release_id", "medium_number", "position"], name: "index_music_tracks_on_release_medium_position", unique: true
    t.index ["release_id"], name: "index_music_tracks_on_release_id"
    t.index ["song_id"], name: "index_music_tracks_on_song_id"
  end

  create_table "penalties", force: :cascade do |t|
    t.string "type", null: false
    t.string "name", null: false
    t.text "description"
    t.bigint "user_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "dynamic_type"
    t.index ["type"], name: "index_penalties_on_type"
    t.index ["user_id"], name: "index_penalties_on_user_id"
  end

  create_table "penalty_applications", force: :cascade do |t|
    t.bigint "penalty_id", null: false
    t.bigint "ranking_configuration_id", null: false
    t.integer "value", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["penalty_id", "ranking_configuration_id"], name: "index_penalty_applications_on_penalty_and_config", unique: true
    t.index ["penalty_id"], name: "index_penalty_applications_on_penalty_id"
    t.index ["ranking_configuration_id"], name: "index_penalty_applications_on_ranking_configuration_id"
  end

  create_table "ranked_items", force: :cascade do |t|
    t.integer "rank"
    t.decimal "score", precision: 10, scale: 2
    t.string "item_type", null: false
    t.bigint "item_id", null: false
    t.bigint "ranking_configuration_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["item_id", "item_type", "ranking_configuration_id"], name: "index_ranked_items_on_item_and_ranking_config_unique", unique: true
    t.index ["item_type", "item_id"], name: "index_ranked_items_on_item"
    t.index ["ranking_configuration_id", "rank"], name: "index_ranked_items_on_config_and_rank"
    t.index ["ranking_configuration_id", "score"], name: "index_ranked_items_on_config_and_score"
    t.index ["ranking_configuration_id"], name: "index_ranked_items_on_ranking_configuration_id"
  end

  create_table "ranked_lists", force: :cascade do |t|
    t.integer "weight"
    t.bigint "list_id", null: false
    t.bigint "ranking_configuration_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["list_id"], name: "index_ranked_lists_on_list_id"
    t.index ["ranking_configuration_id"], name: "index_ranked_lists_on_ranking_configuration_id"
  end

  create_table "ranking_configurations", force: :cascade do |t|
    t.string "type", null: false
    t.string "name", null: false
    t.text "description"
    t.boolean "global", default: true, null: false
    t.boolean "primary", default: false, null: false
    t.boolean "archived", default: false, null: false
    t.datetime "published_at"
    t.integer "algorithm_version", default: 1, null: false
    t.decimal "exponent", precision: 10, scale: 2, default: "3.0", null: false
    t.decimal "bonus_pool_percentage", precision: 10, scale: 2, default: "3.0", null: false
    t.integer "min_list_weight", default: 1, null: false
    t.integer "list_limit"
    t.boolean "apply_list_dates_penalty", default: true, null: false
    t.integer "max_list_dates_penalty_age", default: 50
    t.integer "max_list_dates_penalty_percentage", default: 80
    t.boolean "inherit_penalties", default: true, null: false
    t.bigint "inherited_from_id"
    t.bigint "user_id"
    t.bigint "primary_mapped_list_id"
    t.bigint "secondary_mapped_list_id"
    t.integer "primary_mapped_list_cutoff_limit"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["inherited_from_id"], name: "index_ranking_configurations_on_inherited_from_id"
    t.index ["primary_mapped_list_id"], name: "index_ranking_configurations_on_primary_mapped_list_id"
    t.index ["secondary_mapped_list_id"], name: "index_ranking_configurations_on_secondary_mapped_list_id"
    t.index ["type", "global"], name: "index_ranking_configurations_on_type_and_global"
    t.index ["type", "primary"], name: "index_ranking_configurations_on_type_and_primary"
    t.index ["type", "user_id"], name: "index_ranking_configurations_on_type_and_user_id"
    t.index ["user_id"], name: "index_ranking_configurations_on_user_id"
  end

  create_table "search_index_requests", force: :cascade do |t|
    t.string "parent_type", null: false
    t.bigint "parent_id", null: false
    t.integer "action", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["action"], name: "index_search_index_requests_on_action"
    t.index ["created_at"], name: "index_search_index_requests_on_created_at"
    t.index ["parent_type", "parent_id"], name: "index_search_index_requests_on_parent"
    t.index ["parent_type", "parent_id"], name: "index_search_index_requests_on_parent_type_and_parent_id"
  end

  create_table "users", force: :cascade do |t|
    t.string "auth_uid"
    t.jsonb "auth_data"
    t.string "email"
    t.string "display_name"
    t.string "name"
    t.string "photo_url"
    t.string "original_signup_domain"
    t.integer "role", default: 0, null: false
    t.integer "external_provider"
    t.boolean "email_verified", default: false, null: false
    t.datetime "last_sign_in_at"
    t.integer "sign_in_count"
    t.text "provider_data"
    t.string "stripe_customer_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "confirmed_at"
    t.string "confirmation_token"
    t.datetime "confirmation_sent_at"
    t.index ["auth_uid"], name: "index_users_on_auth_uid"
    t.index ["confirmation_token"], name: "index_users_on_confirmation_token", unique: true
    t.index ["confirmed_at"], name: "index_users_on_confirmed_at"
    t.index ["external_provider"], name: "index_users_on_external_provider"
    t.index ["stripe_customer_id"], name: "index_users_on_stripe_customer_id"
  end

  add_foreign_key "ai_chats", "users"
  add_foreign_key "categories", "categories", column: "parent_id"
  add_foreign_key "category_items", "categories"
  add_foreign_key "list_items", "lists"
  add_foreign_key "list_penalties", "lists"
  add_foreign_key "list_penalties", "penalties"
  add_foreign_key "lists", "users", column: "submitted_by_id"
  add_foreign_key "movies_credits", "movies_people", column: "person_id"
  add_foreign_key "movies_releases", "movies_movies", column: "movie_id"
  add_foreign_key "music_albums", "music_artists", column: "primary_artist_id"
  add_foreign_key "music_credits", "music_artists", column: "artist_id"
  add_foreign_key "music_memberships", "music_artists", column: "artist_id"
  add_foreign_key "music_memberships", "music_artists", column: "member_id"
  add_foreign_key "music_releases", "music_albums", column: "album_id"
  add_foreign_key "music_song_relationships", "music_releases", column: "source_release_id"
  add_foreign_key "music_song_relationships", "music_songs", column: "related_song_id"
  add_foreign_key "music_song_relationships", "music_songs", column: "song_id"
  add_foreign_key "music_tracks", "music_releases", column: "release_id"
  add_foreign_key "music_tracks", "music_songs", column: "song_id"
  add_foreign_key "penalties", "users"
  add_foreign_key "penalty_applications", "penalties"
  add_foreign_key "penalty_applications", "ranking_configurations"
  add_foreign_key "ranked_items", "ranking_configurations"
  add_foreign_key "ranked_lists", "ranking_configurations"
  add_foreign_key "ranking_configurations", "lists", column: "primary_mapped_list_id"
  add_foreign_key "ranking_configurations", "lists", column: "secondary_mapped_list_id"
  add_foreign_key "ranking_configurations", "ranking_configurations", column: "inherited_from_id"
  add_foreign_key "ranking_configurations", "users"
end
