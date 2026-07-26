class Books::MigrateCoverImageJob
  include Sidekiq::Job

  sidekiq_options queue: :default, retry: 5

  def perform(book_id, key, filename, content_type)
    book = Books::Book.find_by(id: book_id)
    return unless book
    return if book.images.where(primary: true).exists?

    response = Services::BooksMigration::LegacyR2.client.get_object(
      bucket: Services::BooksMigration::LegacyR2.bucket,
      key: key
    )

    image = book.images.build(
      primary: true,
      metadata: {source: "legacy_migration", legacy_blob_key: key}
    )
    image.file.attach(
      io: StringIO.new(response.body.read),
      filename: filename,
      content_type: content_type
    )
    image.save!
  end
end
