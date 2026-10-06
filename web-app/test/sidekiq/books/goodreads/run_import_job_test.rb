require "test_helper"

class Books::Goodreads::RunImportJobTest < ActiveSupport::TestCase
  test "runs the import" do
    import = books_goodreads_imports(:regular_user_import)
    ::Services::Books::GoodreadsImports::RunImport.expects(:call).with(import: import)

    Books::Goodreads::RunImportJob.new.perform(import.id)
  end

  test "a deleted import is a no-op" do
    ::Services::Books::GoodreadsImports::RunImport.expects(:call).never

    Books::Goodreads::RunImportJob.new.perform(-1)
  end
end
