class Books::MigrateCoverImageJob
  include Sidekiq::Job

  sidekiq_options queue: :default, retry: 5

  # Namespace for the per-book Postgres advisory lock (arbitrary int4 constant).
  ADVISORY_LOCK_NAMESPACE = 0x626b696d # "bkim"

  def perform(book_id, key, filename, content_type)
    book = Books::Book.find_by(id: book_id)
    return unless book
    return if book.images.where(primary: true).exists?

    response = Services::BooksMigration::LegacyR2.client.get_object(
      bucket: Services::BooksMigration::LegacyR2.bucket,
      key: key
    )
    bytes = response.body.read

    # Serialize concurrent workers for the same book (e.g. a migration re-run
    # enqueued before the first fan-out drains) so they cannot both pass the
    # primary-image guard and create duplicate Images. The transaction-scoped
    # advisory lock releases on commit and only same-book jobs contend; the
    # re-check under the lock skips work the job we waited on already did.
    Books::Book.transaction do
      Books::Book.connection.execute(
        "SELECT pg_advisory_xact_lock(#{ADVISORY_LOCK_NAMESPACE}, #{book.id})"
      )
      next if book.images.where(primary: true).exists?

      image = book.images.build(
        primary: true,
        metadata: {source: "legacy_migration", legacy_blob_key: key}
      )
      image.file.attach(
        io: StringIO.new(bytes),
        filename: filename,
        content_type: content_type
      )
      image.save!
    end
  end
end
