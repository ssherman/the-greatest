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

ActiveRecord::Schema[8.1].define(version: 2026_07_04_204010) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "active_storage_attachments", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.string "key", null: false
    t.text "metadata"
    t.string "service_name", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "ai_chats", force: :cascade do |t|
    t.integer "chat_type", default: 0, null: false
    t.datetime "created_at", null: false
    t.boolean "json_mode", default: false, null: false
    t.jsonb "messages"
    t.string "model", null: false
    t.jsonb "parameters"
    t.bigint "parent_id"
    t.string "parent_type"
    t.integer "provider", default: 0, null: false
    t.jsonb "raw_responses"
    t.jsonb "response_schema"
    t.decimal "temperature", precision: 3, scale: 2, default: "0.2", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.index ["parent_type", "parent_id"], name: "index_ai_chats_on_parent"
    t.index ["user_id"], name: "index_ai_chats_on_user_id"
  end

  create_table "books_author_relationships", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "from_author_id", null: false
    t.integer "relation_type", default: 0, null: false
    t.bigint "to_author_id", null: false
    t.datetime "updated_at", null: false
    t.index ["from_author_id", "to_author_id", "relation_type"], name: "index_books_author_relationships_unique", unique: true
    t.index ["from_author_id"], name: "index_books_author_relationships_on_from_author_id"
    t.index ["to_author_id"], name: "index_books_author_relationships_on_to_author_id"
  end

  create_table "books_authors", force: :cascade do |t|
    t.string "alternate_names", default: [], null: false, array: true
    t.integer "birth_year"
    t.datetime "created_at", null: false
    t.integer "death_year"
    t.text "description"
    t.integer "kind", default: 0, null: false
    t.string "name", null: false
    t.string "slug", null: false
    t.string "sort_name"
    t.datetime "updated_at", null: false
    t.index ["alternate_names"], name: "index_books_authors_on_alternate_names", using: :gin
    t.index ["kind"], name: "index_books_authors_on_kind"
    t.index ["slug"], name: "index_books_authors_on_slug", unique: true
  end

  create_table "books_book_authors", force: :cascade do |t|
    t.bigint "author_id", null: false
    t.bigint "book_id", null: false
    t.datetime "created_at", null: false
    t.string "credited_as"
    t.integer "position"
    t.integer "role", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["author_id"], name: "index_books_book_authors_on_author_id"
    t.index ["book_id", "author_id"], name: "index_books_book_authors_on_book_id_and_author_id", unique: true
    t.index ["book_id"], name: "index_books_book_authors_on_book_id"
  end

  create_table "books_book_relationships", force: :cascade do |t|
    t.bigint "book_id", null: false
    t.datetime "created_at", null: false
    t.bigint "related_book_id", null: false
    t.integer "relation_type", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["book_id", "related_book_id", "relation_type"], name: "index_books_book_relationships_unique", unique: true
    t.index ["book_id"], name: "index_books_book_relationships_on_book_id"
    t.index ["related_book_id"], name: "index_books_book_relationships_on_related_book_id"
  end

  create_table "books_books", force: :cascade do |t|
    t.string "alternate_titles", default: [], null: false, array: true
    t.integer "book_kind", default: 0, null: false
    t.datetime "created_at", null: false
    t.bigint "default_edition_id"
    t.text "description"
    t.integer "first_published_year"
    t.bigint "original_language_id"
    t.string "slug", null: false
    t.string "sort_title"
    t.string "subtitle"
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["alternate_titles"], name: "index_books_books_on_alternate_titles", using: :gin
    t.index ["book_kind"], name: "index_books_books_on_book_kind"
    t.index ["default_edition_id"], name: "index_books_books_on_default_edition_id"
    t.index ["first_published_year"], name: "index_books_books_on_first_published_year"
    t.index ["original_language_id"], name: "index_books_books_on_original_language_id"
    t.index ["slug"], name: "index_books_books_on_slug", unique: true
  end

  create_table "books_credits", force: :cascade do |t|
    t.bigint "author_id", null: false
    t.datetime "created_at", null: false
    t.bigint "creditable_id", null: false
    t.string "creditable_type", null: false
    t.integer "position"
    t.integer "role", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["author_id", "role"], name: "index_books_credits_on_author_id_and_role"
    t.index ["author_id"], name: "index_books_credits_on_author_id"
    t.index ["creditable_type", "creditable_id"], name: "index_books_credits_on_creditable"
  end

  create_table "books_editions", force: :cascade do |t|
    t.integer "book_binding"
    t.bigint "book_id", null: false
    t.datetime "created_at", null: false
    t.integer "edition_type", default: 0, null: false
    t.bigint "language_id"
    t.jsonb "metadata", default: {}, null: false
    t.integer "page_count"
    t.integer "popularity"
    t.integer "publication_year"
    t.string "publisher_name"
    t.string "subtitle"
    t.string "title"
    t.datetime "updated_at", null: false
    t.integer "volume_number"
    t.index ["book_id"], name: "index_books_editions_on_book_id"
    t.index ["edition_type"], name: "index_books_editions_on_edition_type"
    t.index ["language_id"], name: "index_books_editions_on_language_id"
    t.index ["volume_number"], name: "index_books_editions_on_volume_number"
  end

  create_table "books_series", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.bigint "representative_book_id"
    t.string "slug", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["representative_book_id"], name: "index_books_series_on_representative_book_id"
    t.index ["slug"], name: "index_books_series_on_slug", unique: true
    t.index ["title"], name: "index_books_series_on_title"
  end

  create_table "books_series_books", force: :cascade do |t|
    t.bigint "book_id", null: false
    t.datetime "created_at", null: false
    t.boolean "numbered", default: true, null: false
    t.decimal "position", precision: 8, scale: 2
    t.string "position_label"
    t.bigint "series_id", null: false
    t.datetime "updated_at", null: false
    t.index ["book_id"], name: "index_books_series_books_on_book_id"
    t.index ["series_id", "book_id"], name: "index_books_series_books_on_series_id_and_book_id", unique: true
    t.index ["series_id"], name: "index_books_series_books_on_series_id"
  end

  create_table "categories", force: :cascade do |t|
    t.string "alternative_names", default: [], array: true
    t.integer "category_type", default: 0
    t.datetime "created_at", null: false
    t.boolean "deleted", default: false
    t.text "description"
    t.integer "import_source"
    t.integer "item_count", default: 0
    t.string "name", null: false
    t.bigint "parent_id"
    t.string "slug"
    t.string "type", null: false
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
    t.datetime "created_at", null: false
    t.bigint "item_id", null: false
    t.string "item_type", null: false
    t.datetime "updated_at", null: false
    t.index ["category_id", "item_type", "item_id"], name: "index_category_items_on_category_id_and_item_type_and_item_id", unique: true
    t.index ["category_id"], name: "index_category_items_on_category_id"
    t.index ["item_type", "item_id"], name: "index_category_items_on_item"
    t.index ["item_type", "item_id"], name: "index_category_items_on_item_type_and_item_id"
  end

  create_table "domain_roles", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "domain", null: false
    t.integer "permission_level", default: 0, null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["domain"], name: "index_domain_roles_on_domain"
    t.index ["permission_level"], name: "index_domain_roles_on_permission_level"
    t.index ["user_id", "domain"], name: "index_domain_roles_on_user_id_and_domain", unique: true
    t.index ["user_id"], name: "index_domain_roles_on_user_id"
  end

  create_table "external_links", force: :cascade do |t|
    t.integer "click_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.integer "link_category"
    t.jsonb "metadata", default: "{}"
    t.string "name", null: false
    t.bigint "parent_id", null: false
    t.string "parent_type", null: false
    t.integer "price_cents"
    t.boolean "public", default: true, null: false
    t.integer "source"
    t.string "source_name"
    t.bigint "submitted_by_id"
    t.datetime "updated_at", null: false
    t.string "url", null: false
    t.index ["click_count"], name: "index_external_links_on_click_count", order: :desc
    t.index ["parent_type", "parent_id"], name: "index_external_links_on_parent"
    t.index ["parent_type", "parent_id"], name: "index_external_links_on_parent_type_and_parent_id"
    t.index ["public"], name: "index_external_links_on_public"
    t.index ["source"], name: "index_external_links_on_source"
    t.index ["submitted_by_id"], name: "index_external_links_on_submitted_by_id"
  end

  create_table "friendly_id_slugs", force: :cascade do |t|
    t.datetime "created_at"
    t.string "scope"
    t.string "slug", null: false
    t.integer "sluggable_id", null: false
    t.string "sluggable_type", limit: 50
    t.index ["slug", "sluggable_type", "scope"], name: "index_friendly_id_slugs_on_slug_and_sluggable_type_and_scope", unique: true
    t.index ["slug", "sluggable_type"], name: "index_friendly_id_slugs_on_slug_and_sluggable_type"
    t.index ["sluggable_type", "sluggable_id"], name: "index_friendly_id_slugs_on_sluggable_type_and_sluggable_id"
  end

  create_table "games_companies", force: :cascade do |t|
    t.string "country", limit: 2
    t.datetime "created_at", null: false
    t.text "description"
    t.string "name", null: false
    t.string "slug", null: false
    t.datetime "updated_at", null: false
    t.integer "year_founded"
    t.index ["name"], name: "index_games_companies_on_name"
    t.index ["slug"], name: "index_games_companies_on_slug", unique: true
  end

  create_table "games_game_companies", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.datetime "created_at", null: false
    t.boolean "developer", default: false, null: false
    t.bigint "game_id", null: false
    t.boolean "publisher", default: false, null: false
    t.datetime "updated_at", null: false
    t.index ["company_id"], name: "index_games_game_companies_on_company_id"
    t.index ["developer"], name: "index_games_game_companies_on_developer"
    t.index ["game_id", "company_id"], name: "index_games_game_companies_on_game_and_company", unique: true
    t.index ["game_id"], name: "index_games_game_companies_on_game_id"
    t.index ["publisher"], name: "index_games_game_companies_on_publisher"
  end

  create_table "games_game_platforms", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "game_id", null: false
    t.bigint "platform_id", null: false
    t.datetime "updated_at", null: false
    t.index ["game_id", "platform_id"], name: "index_games_game_platforms_on_game_and_platform", unique: true
    t.index ["game_id"], name: "index_games_game_platforms_on_game_id"
    t.index ["platform_id"], name: "index_games_game_platforms_on_platform_id"
  end

  create_table "games_games", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.integer "game_type", default: 0, null: false
    t.bigint "parent_game_id"
    t.integer "release_year"
    t.bigint "series_id"
    t.string "slug", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["game_type"], name: "index_games_games_on_game_type"
    t.index ["parent_game_id"], name: "index_games_games_on_parent_game_id"
    t.index ["release_year"], name: "index_games_games_on_release_year"
    t.index ["series_id"], name: "index_games_games_on_series_id"
    t.index ["slug"], name: "index_games_games_on_slug", unique: true
  end

  create_table "games_platforms", force: :cascade do |t|
    t.string "abbreviation"
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.integer "platform_family"
    t.string "slug", null: false
    t.datetime "updated_at", null: false
    t.index ["platform_family"], name: "index_games_platforms_on_platform_family"
    t.index ["slug"], name: "index_games_platforms_on_slug", unique: true
  end

  create_table "games_series", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.string "name", null: false
    t.string "slug", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_games_series_on_name"
    t.index ["slug"], name: "index_games_series_on_slug", unique: true
  end

  create_table "identifiers", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "identifiable_id", null: false
    t.string "identifiable_type", null: false
    t.integer "identifier_type", null: false
    t.datetime "updated_at", null: false
    t.string "value", null: false
    t.index ["identifiable_type", "identifiable_id"], name: "index_identifiers_on_identifiable"
    t.index ["identifiable_type", "identifier_type", "value", "identifiable_id"], name: "index_identifiers_on_lookup_unique", unique: true
    t.index ["identifiable_type", "value"], name: "index_identifiers_on_type_and_value"
  end

  create_table "images", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.json "metadata", default: {}
    t.text "notes"
    t.bigint "parent_id", null: false
    t.string "parent_type", null: false
    t.boolean "primary", default: false, null: false
    t.datetime "updated_at", null: false
    t.index ["parent_type", "parent_id", "primary"], name: "index_images_on_parent_and_primary"
    t.index ["parent_type", "parent_id"], name: "index_images_on_parent"
  end

  create_table "languages", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "iso_639_1", limit: 2
    t.string "iso_639_3", limit: 3
    t.string "name", null: false
    t.string "slug", null: false
    t.datetime "updated_at", null: false
    t.index ["iso_639_3"], name: "index_languages_on_iso_639_3", unique: true
    t.index ["name"], name: "index_languages_on_name"
    t.index ["slug"], name: "index_languages_on_slug", unique: true
  end

  create_table "legacy_id_maps", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "legacy_id", null: false
    t.string "model", null: false
    t.bigint "new_id", null: false
    t.datetime "updated_at", null: false
    t.index ["model", "legacy_id"], name: "index_legacy_id_maps_on_model_and_legacy_id", unique: true
  end

  create_table "list_items", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "list_id", null: false
    t.bigint "listable_id"
    t.string "listable_type"
    t.jsonb "metadata", default: {}
    t.integer "position"
    t.datetime "updated_at", null: false
    t.boolean "verified", default: false, null: false
    t.index ["list_id", "listable_type", "listable_id"], name: "index_list_items_on_list_and_listable_unique", unique: true
    t.index ["list_id", "position"], name: "index_list_items_on_list_id_and_position"
    t.index ["list_id"], name: "index_list_items_on_list_id"
    t.index ["listable_type", "listable_id"], name: "index_list_items_on_listable"
  end

  create_table "list_penalties", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "list_id", null: false
    t.bigint "penalty_id", null: false
    t.datetime "updated_at", null: false
    t.index ["list_id", "penalty_id"], name: "index_list_penalties_on_list_and_penalty", unique: true
    t.index ["list_id"], name: "index_list_penalties_on_list_id"
    t.index ["penalty_id"], name: "index_list_penalties_on_penalty_id"
  end

  create_table "lists", force: :cascade do |t|
    t.boolean "category_specific"
    t.datetime "created_at", null: false
    t.boolean "creator_specific"
    t.text "description"
    t.integer "estimated_quality", default: 0, null: false
    t.boolean "high_quality_source"
    t.jsonb "items_json"
    t.boolean "location_specific"
    t.string "musicbrainz_series_id"
    t.string "name", null: false
    t.integer "num_years_covered"
    t.integer "number_of_voters"
    t.text "raw_content"
    t.text "simplified_content"
    t.string "source"
    t.string "source_country_origin"
    t.integer "status", default: 0, null: false
    t.bigint "submitted_by_id"
    t.string "type", null: false
    t.datetime "updated_at", null: false
    t.string "url"
    t.boolean "voter_count_estimated"
    t.boolean "voter_count_unknown"
    t.boolean "voter_names_unknown"
    t.jsonb "wizard_state", default: {}
    t.integer "year_published"
    t.boolean "yearly_award"
    t.index ["submitted_by_id"], name: "index_lists_on_submitted_by_id"
  end

  create_table "movies_credits", force: :cascade do |t|
    t.string "character_name"
    t.datetime "created_at", null: false
    t.bigint "creditable_id", null: false
    t.string "creditable_type", null: false
    t.bigint "person_id", null: false
    t.integer "position"
    t.integer "role", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["creditable_type", "creditable_id"], name: "index_movies_credits_on_creditable"
    t.index ["creditable_type", "creditable_id"], name: "index_movies_credits_on_creditable_type_and_creditable_id"
    t.index ["person_id", "role"], name: "index_movies_credits_on_person_id_and_role"
    t.index ["person_id"], name: "index_movies_credits_on_person_id"
  end

  create_table "movies_movies", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.integer "rating"
    t.integer "release_year"
    t.integer "runtime_minutes"
    t.string "slug", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["rating"], name: "index_movies_movies_on_rating"
    t.index ["release_year"], name: "index_movies_movies_on_release_year"
    t.index ["slug"], name: "index_movies_movies_on_slug", unique: true
  end

  create_table "movies_people", force: :cascade do |t|
    t.date "born_on"
    t.string "country", limit: 2
    t.datetime "created_at", null: false
    t.text "description"
    t.date "died_on"
    t.integer "gender"
    t.string "name", null: false
    t.string "slug", null: false
    t.datetime "updated_at", null: false
    t.index ["gender"], name: "index_movies_people_on_gender"
    t.index ["slug"], name: "index_movies_people_on_slug", unique: true
  end

  create_table "movies_releases", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.boolean "is_primary", default: false, null: false
    t.jsonb "metadata"
    t.bigint "movie_id", null: false
    t.date "release_date"
    t.integer "release_format", default: 0, null: false
    t.string "release_name"
    t.integer "runtime_minutes"
    t.datetime "updated_at", null: false
    t.index ["is_primary"], name: "index_movies_releases_on_is_primary"
    t.index ["movie_id", "release_name", "release_format"], name: "index_movies_releases_on_movie_and_name_and_format", unique: true
    t.index ["movie_id"], name: "index_movies_releases_on_movie_id"
    t.index ["release_date"], name: "index_movies_releases_on_release_date"
    t.index ["release_format"], name: "index_movies_releases_on_release_format"
  end

  create_table "music_album_artists", force: :cascade do |t|
    t.bigint "album_id", null: false
    t.bigint "artist_id", null: false
    t.datetime "created_at", null: false
    t.integer "position", default: 1
    t.datetime "updated_at", null: false
    t.index ["album_id", "artist_id"], name: "index_music_album_artists_on_album_id_and_artist_id", unique: true
    t.index ["album_id", "position"], name: "index_music_album_artists_on_album_id_and_position"
    t.index ["album_id"], name: "index_music_album_artists_on_album_id"
    t.index ["artist_id"], name: "index_music_album_artists_on_artist_id"
  end

  create_table "music_albums", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.integer "release_year"
    t.string "slug", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["release_year"], name: "index_music_albums_on_release_year"
    t.index ["slug"], name: "index_music_albums_on_slug", unique: true
  end

  create_table "music_artists", force: :cascade do |t|
    t.date "born_on"
    t.string "country", limit: 2
    t.datetime "created_at", null: false
    t.text "description"
    t.integer "kind", default: 0, null: false
    t.string "name", null: false
    t.string "slug", null: false
    t.datetime "updated_at", null: false
    t.integer "year_died"
    t.integer "year_disbanded"
    t.integer "year_formed"
    t.index ["kind"], name: "index_music_artists_on_kind"
    t.index ["slug"], name: "index_music_artists_on_slug", unique: true
  end

  create_table "music_credits", force: :cascade do |t|
    t.bigint "artist_id", null: false
    t.datetime "created_at", null: false
    t.bigint "creditable_id", null: false
    t.string "creditable_type", null: false
    t.integer "position"
    t.integer "role", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["artist_id", "role"], name: "index_music_credits_on_artist_id_and_role"
    t.index ["artist_id"], name: "index_music_credits_on_artist_id"
    t.index ["creditable_type", "creditable_id"], name: "index_music_credits_on_creditable"
    t.index ["creditable_type", "creditable_id"], name: "index_music_credits_on_creditable_type_and_creditable_id"
  end

  create_table "music_memberships", force: :cascade do |t|
    t.bigint "artist_id", null: false
    t.datetime "created_at", null: false
    t.date "joined_on"
    t.date "left_on"
    t.bigint "member_id", null: false
    t.datetime "updated_at", null: false
    t.index ["artist_id", "member_id", "joined_on"], name: "index_music_memberships_on_artist_member_joined", unique: true
    t.index ["artist_id"], name: "index_music_memberships_on_artist_id"
    t.index ["member_id"], name: "index_music_memberships_on_member_id"
  end

  create_table "music_releases", force: :cascade do |t|
    t.bigint "album_id", null: false
    t.string "country"
    t.datetime "created_at", null: false
    t.integer "format", default: 0, null: false
    t.string "labels", default: [], array: true
    t.jsonb "metadata"
    t.date "release_date"
    t.string "release_name"
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["album_id"], name: "index_music_releases_on_album_id"
    t.index ["country"], name: "index_music_releases_on_country"
    t.index ["status"], name: "index_music_releases_on_status"
  end

  create_table "music_song_artists", force: :cascade do |t|
    t.bigint "artist_id", null: false
    t.datetime "created_at", null: false
    t.integer "position", default: 1
    t.bigint "song_id", null: false
    t.datetime "updated_at", null: false
    t.index ["artist_id"], name: "index_music_song_artists_on_artist_id"
    t.index ["song_id", "artist_id"], name: "index_music_song_artists_on_song_id_and_artist_id", unique: true
    t.index ["song_id", "position"], name: "index_music_song_artists_on_song_id_and_position"
    t.index ["song_id"], name: "index_music_song_artists_on_song_id"
  end

  create_table "music_song_relationships", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "related_song_id", null: false
    t.integer "relation_type", default: 0, null: false
    t.bigint "song_id", null: false
    t.bigint "source_release_id"
    t.datetime "updated_at", null: false
    t.index ["related_song_id"], name: "index_music_song_relationships_on_related_song_id"
    t.index ["song_id", "related_song_id", "relation_type"], name: "index_music_song_relationships_on_song_related_type", unique: true
    t.index ["song_id"], name: "index_music_song_relationships_on_song_id"
    t.index ["source_release_id"], name: "index_music_song_relationships_on_source_release_id"
  end

  create_table "music_songs", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.integer "duration_secs"
    t.string "isrc", limit: 12
    t.text "lyrics"
    t.text "notes"
    t.integer "release_year"
    t.string "slug", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["isrc"], name: "index_music_songs_on_isrc", unique: true, where: "(isrc IS NOT NULL)"
    t.index ["release_year"], name: "index_music_songs_on_release_year"
    t.index ["slug"], name: "index_music_songs_on_slug", unique: true
  end

  create_table "music_tracks", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "length_secs"
    t.integer "medium_number", default: 1, null: false
    t.text "notes"
    t.integer "position", null: false
    t.bigint "release_id", null: false
    t.bigint "song_id", null: false
    t.datetime "updated_at", null: false
    t.index ["release_id", "medium_number", "position"], name: "index_music_tracks_on_release_medium_position", unique: true
    t.index ["release_id"], name: "index_music_tracks_on_release_id"
    t.index ["song_id"], name: "index_music_tracks_on_song_id"
  end

  create_table "penalties", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.integer "dynamic_type"
    t.string "name", null: false
    t.string "type", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.index ["type"], name: "index_penalties_on_type"
    t.index ["user_id"], name: "index_penalties_on_user_id"
  end

  create_table "penalty_applications", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "penalty_id", null: false
    t.bigint "ranking_configuration_id", null: false
    t.datetime "updated_at", null: false
    t.integer "value", default: 0, null: false
    t.index ["penalty_id", "ranking_configuration_id"], name: "index_penalty_applications_on_penalty_and_config", unique: true
    t.index ["penalty_id"], name: "index_penalty_applications_on_penalty_id"
    t.index ["ranking_configuration_id"], name: "index_penalty_applications_on_ranking_configuration_id"
  end

  create_table "ranked_items", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "item_id", null: false
    t.string "item_type", null: false
    t.integer "rank"
    t.bigint "ranking_configuration_id", null: false
    t.decimal "score", precision: 10, scale: 2
    t.datetime "updated_at", null: false
    t.index ["item_id", "item_type", "ranking_configuration_id"], name: "index_ranked_items_on_item_and_ranking_config_unique", unique: true
    t.index ["item_type", "item_id"], name: "index_ranked_items_on_item"
    t.index ["ranking_configuration_id", "rank"], name: "index_ranked_items_on_config_and_rank"
    t.index ["ranking_configuration_id", "score"], name: "index_ranked_items_on_config_and_score"
    t.index ["ranking_configuration_id"], name: "index_ranked_items_on_ranking_configuration_id"
  end

  create_table "ranked_lists", force: :cascade do |t|
    t.jsonb "calculated_weight_details"
    t.datetime "created_at", null: false
    t.bigint "list_id", null: false
    t.bigint "ranking_configuration_id", null: false
    t.datetime "updated_at", null: false
    t.integer "weight"
    t.index ["list_id"], name: "index_ranked_lists_on_list_id"
    t.index ["ranking_configuration_id"], name: "index_ranked_lists_on_ranking_configuration_id"
  end

  create_table "ranking_configurations", force: :cascade do |t|
    t.integer "algorithm_version", default: 1, null: false
    t.boolean "apply_list_dates_penalty", default: true, null: false
    t.boolean "archived", default: false, null: false
    t.decimal "bonus_pool_percentage", precision: 10, scale: 2, default: "3.0", null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.decimal "exponent", precision: 10, scale: 2, default: "3.0", null: false
    t.boolean "global", default: true, null: false
    t.boolean "inherit_penalties", default: true, null: false
    t.bigint "inherited_from_id"
    t.integer "list_limit"
    t.integer "max_list_dates_penalty_age", default: 50
    t.integer "max_list_dates_penalty_percentage", default: 80
    t.integer "min_list_weight", default: 1, null: false
    t.string "name", null: false
    t.boolean "primary", default: false, null: false
    t.integer "primary_mapped_list_cutoff_limit"
    t.bigint "primary_mapped_list_id"
    t.datetime "published_at"
    t.bigint "secondary_mapped_list_id"
    t.string "type", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.index ["inherited_from_id"], name: "index_ranking_configurations_on_inherited_from_id"
    t.index ["primary_mapped_list_id"], name: "index_ranking_configurations_on_primary_mapped_list_id"
    t.index ["secondary_mapped_list_id"], name: "index_ranking_configurations_on_secondary_mapped_list_id"
    t.index ["type", "global"], name: "index_ranking_configurations_on_type_and_global"
    t.index ["type", "primary"], name: "index_ranking_configurations_on_type_and_primary"
    t.index ["type", "user_id"], name: "index_ranking_configurations_on_type_and_user_id"
    t.index ["user_id"], name: "index_ranking_configurations_on_user_id"
  end

  create_table "search_index_requests", force: :cascade do |t|
    t.integer "action", null: false
    t.datetime "created_at", null: false
    t.bigint "parent_id", null: false
    t.string "parent_type", null: false
    t.datetime "updated_at", null: false
    t.index ["action"], name: "index_search_index_requests_on_action"
    t.index ["created_at"], name: "index_search_index_requests_on_created_at"
    t.index ["parent_type", "parent_id"], name: "index_search_index_requests_on_parent"
    t.index ["parent_type", "parent_id"], name: "index_search_index_requests_on_parent_type_and_parent_id"
  end

  create_table "user_list_items", force: :cascade do |t|
    t.date "completed_on"
    t.datetime "created_at", null: false
    t.bigint "listable_id", null: false
    t.string "listable_type", null: false
    t.integer "position", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_list_id", null: false
    t.index ["listable_type", "listable_id"], name: "index_user_list_items_on_listable"
    t.index ["user_list_id", "completed_on"], name: "index_user_list_items_on_user_list_id_and_completed_on"
    t.index ["user_list_id", "listable_type", "listable_id"], name: "index_user_list_items_on_list_and_listable_unique", unique: true
    t.index ["user_list_id", "position"], name: "index_user_list_items_on_user_list_id_and_position"
    t.index ["user_list_id"], name: "index_user_list_items_on_user_list_id"
  end

  create_table "user_lists", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.integer "list_type", null: false
    t.string "name", null: false
    t.integer "position"
    t.boolean "public", default: false, null: false
    t.string "type", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.integer "view_mode", default: 0, null: false
    t.index ["public"], name: "index_user_lists_on_public", where: "(public = true)"
    t.index ["user_id", "type"], name: "index_user_lists_on_user_id_and_type"
    t.index ["user_id"], name: "index_user_lists_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.jsonb "auth_data"
    t.string "auth_uid"
    t.datetime "confirmation_sent_at"
    t.string "confirmation_token"
    t.datetime "confirmed_at"
    t.datetime "created_at", null: false
    t.string "display_name"
    t.string "email"
    t.boolean "email_verified", default: false, null: false
    t.integer "external_provider"
    t.datetime "last_sign_in_at"
    t.string "name"
    t.string "original_signup_domain"
    t.string "photo_url"
    t.text "provider_data"
    t.integer "role", default: 0, null: false
    t.integer "sign_in_count"
    t.string "stripe_customer_id"
    t.datetime "updated_at", null: false
    t.index ["auth_uid"], name: "index_users_on_auth_uid"
    t.index ["confirmation_token"], name: "index_users_on_confirmation_token", unique: true
    t.index ["confirmed_at"], name: "index_users_on_confirmed_at"
    t.index ["external_provider"], name: "index_users_on_external_provider"
    t.index ["stripe_customer_id"], name: "index_users_on_stripe_customer_id"
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "ai_chats", "users"
  add_foreign_key "books_author_relationships", "books_authors", column: "from_author_id"
  add_foreign_key "books_author_relationships", "books_authors", column: "to_author_id"
  add_foreign_key "books_book_authors", "books_authors", column: "author_id"
  add_foreign_key "books_book_authors", "books_books", column: "book_id"
  add_foreign_key "books_book_relationships", "books_books", column: "book_id"
  add_foreign_key "books_book_relationships", "books_books", column: "related_book_id"
  add_foreign_key "books_books", "books_editions", column: "default_edition_id", on_delete: :nullify
  add_foreign_key "books_books", "languages", column: "original_language_id"
  add_foreign_key "books_credits", "books_authors", column: "author_id"
  add_foreign_key "books_editions", "books_books", column: "book_id"
  add_foreign_key "books_editions", "languages"
  add_foreign_key "books_series", "books_books", column: "representative_book_id", on_delete: :nullify
  add_foreign_key "books_series_books", "books_books", column: "book_id"
  add_foreign_key "books_series_books", "books_series", column: "series_id"
  add_foreign_key "categories", "categories", column: "parent_id"
  add_foreign_key "category_items", "categories"
  add_foreign_key "domain_roles", "users"
  add_foreign_key "external_links", "users", column: "submitted_by_id"
  add_foreign_key "games_game_companies", "games_companies", column: "company_id"
  add_foreign_key "games_game_companies", "games_games", column: "game_id"
  add_foreign_key "games_game_platforms", "games_games", column: "game_id"
  add_foreign_key "games_game_platforms", "games_platforms", column: "platform_id"
  add_foreign_key "games_games", "games_games", column: "parent_game_id"
  add_foreign_key "games_games", "games_series", column: "series_id"
  add_foreign_key "list_items", "lists"
  add_foreign_key "list_penalties", "lists"
  add_foreign_key "list_penalties", "penalties"
  add_foreign_key "lists", "users", column: "submitted_by_id"
  add_foreign_key "movies_credits", "movies_people", column: "person_id"
  add_foreign_key "movies_releases", "movies_movies", column: "movie_id"
  add_foreign_key "music_album_artists", "music_albums", column: "album_id"
  add_foreign_key "music_album_artists", "music_artists", column: "artist_id"
  add_foreign_key "music_credits", "music_artists", column: "artist_id"
  add_foreign_key "music_memberships", "music_artists", column: "artist_id"
  add_foreign_key "music_memberships", "music_artists", column: "member_id"
  add_foreign_key "music_releases", "music_albums", column: "album_id"
  add_foreign_key "music_song_artists", "music_artists", column: "artist_id"
  add_foreign_key "music_song_artists", "music_songs", column: "song_id"
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
  add_foreign_key "user_list_items", "user_lists"
  add_foreign_key "user_lists", "users"
end
