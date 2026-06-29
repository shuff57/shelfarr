# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class Opds::CatalogControllerTest < ActionDispatch::IntegrationTest
  def auth_headers(username = "userone", password = "Password123!")
    { "Authorization" => ActionController::HttpAuthentication::Basic.encode_credentials(username, password) }
  end

  test "root requires basic auth" do
    get opds_root_path
    assert_response :unauthorized
  end

  test "root rejects bad credentials" do
    get opds_root_path, headers: auth_headers("userone", "wrong")
    assert_response :unauthorized
  end

  test "root returns a navigation feed" do
    get opds_root_path, headers: auth_headers
    assert_response :success
    assert_match "kind=navigation", response.headers["Content-Type"]
    assert_match "All Books", response.body
    assert_match opds_books_path, response.body
  end

  test "books feed lists acquired ebooks with acquisition links" do
    Dir.mktmpdir do |dir|
      SettingsService.set(:ebook_output_path, dir)
      File.write(File.join(dir, "book.epub"), "x")
      ebook = Book.create!(title: "Readable Ebook", author: "Some Author", book_type: :ebook, file_path: dir)

      get opds_books_path, headers: auth_headers
      assert_response :success
      assert_match "kind=acquisition", response.headers["Content-Type"]
      assert_match "Readable Ebook", response.body
      assert_match opds_book_download_path(ebook), response.body
      assert_match "application/epub+zip", response.body
    end
  end

  test "books feed excludes audiobooks" do
    audiobook = books(:audiobook_acquired)
    get opds_books_path, headers: auth_headers
    assert_response :success
    assert_no_match(/#{Regexp.escape(audiobook.title)}/, response.body)
  end

  test "download streams the book file" do
    Dir.mktmpdir do |dir|
      SettingsService.set(:ebook_output_path, dir)
      File.write(File.join(dir, "book.epub"), "EPUBBYTES")
      book = Book.create!(title: "E", book_type: :ebook, file_path: dir)

      get opds_book_download_path(book), headers: auth_headers
      assert_response :success
      assert_equal "application/epub+zip", response.media_type
      assert_equal "EPUBBYTES", response.body
    end
  end

  test "download requires auth" do
    get opds_book_download_path(books(:audiobook_acquired))
    assert_response :unauthorized
  end
end
