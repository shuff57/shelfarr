class Book < ApplicationRecord
  METADATA_SOURCE_NAMES = MetadataSources::NAMES

  has_many :requests, dependent: :restrict_with_error
  has_many :uploads, dependent: :nullify
  has_many :reading_progresses, dependent: :destroy

  enum :book_type, { audiobook: 0, ebook: 1 }

  validates :title, presence: true
  validates :book_type, presence: true

  scope :audiobooks, -> { where(book_type: :audiobook) }
  scope :ebooks, -> { where(book_type: :ebook) }
  scope :acquired, -> { where.not(file_path: nil) }
  scope :pending, -> { where(file_path: nil) }

  def acquired?
    file_path.present?
  end

  # Maps a file extension to the in-browser reader that handles it.
  READER_FORMATS = { "epub" => :epub, "pdf" => :pdf, "cbz" => :comic, "cbr" => :comic }.freeze

  # MIME type per reader format, for file streaming and OPDS acquisition links.
  MIME_TYPES = {
    epub: "application/epub+zip",
    pdf: "application/pdf",
    comic: "application/vnd.comicbook+zip"
  }.freeze

  def content_type
    MIME_TYPES.fetch(reader_format, "application/octet-stream")
  end

  def self.content_type_for_path(path)
    MIME_TYPES.fetch(new.reader_format_for(path), "application/octet-stream")
  end

  # The on-disk file to read: file_path itself when it is a readable file, else
  # the largest reader-format file inside the directory. nil when none exists.
  def primary_file
    return nil if file_path.blank?

    if File.file?(file_path)
      return reader_format_for(file_path) ? file_path : nil
    end
    return nil unless File.directory?(file_path)

    Dir.glob(File.join(file_path, "**", "*"))
       .select { |f| File.file?(f) && reader_format_for(f) }
       .max_by { |f| File.size(f) }
  end

  # :epub, :pdf, :comic, or nil for the book's primary file.
  def reader_format
    reader_format_for(primary_file)
  end

  # Only ebooks with a renderable file can be opened in the reader.
  def readable?
    ebook? && reader_format.present?
  end

  def reader_format_for(path)
    return nil if path.blank?

    READER_FORMATS[File.extname(path.to_s).delete_prefix(".").downcase]
  end

  def display_name
    author.present? ? "#{title} by #{author}" : title
  end

  def metadata_source_name
    return nil if unified_work_id.blank?

    source, = Book.parse_work_id(unified_work_id)
    MetadataSources.display_name(source)
  end

  def metadata_source_url
    return nil if unified_work_id.blank?

    source, source_id = Book.parse_work_id(unified_work_id)
    return nil if source_id.blank?

    case source
    when "hardcover"
      "https://hardcover.app/books/#{source_id}"
    when "google_books"
      "https://books.google.com/books?id=#{source_id}"
    when "openlibrary"
      "https://openlibrary.org/works/#{source_id}"
    end
  end

  def metadata_source_attribution
    return nil if metadata_source_name.blank?

    "Metadata from #{metadata_source_name}"
  end

  # Returns unified work_id in format "source:id"
  def unified_work_id
    if hardcover_id.present?
      "hardcover:#{hardcover_id}"
    elsif google_books_id.present?
      "google_books:#{google_books_id}"
    elsif open_library_work_id.present?
      "openlibrary:#{open_library_work_id}"
    end
  end

  # Parse a work_id into [source, source_id]
  # Handles both prefixed ("hardcover:123") and legacy ("OL45804W") formats
  def self.parse_work_id(work_id)
    parts = work_id.to_s.split(":", 2)
    if parts.length == 2
      parts
    else
      # Legacy OpenLibrary IDs without prefix
      [ "openlibrary", work_id ]
    end
  end

  # Find a book by work_id and book_type
  def self.find_by_work_id(work_id, book_type:)
    source, source_id = parse_work_id(work_id)
    case source
    when "hardcover"
      find_by(hardcover_id: source_id, book_type: book_type)
    when "google_books"
      find_by(google_books_id: source_id, book_type: book_type)
    else
      find_by(open_library_work_id: source_id, book_type: book_type)
    end
  end

  def self.find_by_any_work_id(work_ids, book_type:)
    find_in_lookup(preload_by_work_ids(work_ids), work_ids, book_type: book_type)
  end

  def self.find_in_lookup(lookup, work_ids, book_type:)
    Array(work_ids).each do |work_id|
      source, source_id = parse_work_id(work_id)
      lookup_keys = [ work_id.to_s, "#{source}:#{source_id}" ].uniq
      book = lookup_keys.filter_map { |key| lookup.dig(key, book_type.to_s) }.first
      return book if book
    end

    nil
  end

  def self.preload_by_work_ids(work_ids)
    ids = Array(work_ids).compact_blank.map(&:to_s).uniq
    return {} if ids.empty?

    hardcover_ids = []
    google_books_ids = []
    openlibrary_ids = []

    ids.each do |work_id|
      source, source_id = parse_work_id(work_id)
      next if source_id.blank?

      case source
      when "hardcover"
        hardcover_ids << source_id
      when "google_books"
        google_books_ids << source_id
      else
        openlibrary_ids << source_id
      end
    end

    scope = none
    scope = scope.or(where(hardcover_id: hardcover_ids)) if hardcover_ids.any?
    scope = scope.or(where(google_books_id: google_books_ids)) if google_books_ids.any?
    scope = scope.or(where(open_library_work_id: openlibrary_ids)) if openlibrary_ids.any?

    lookup = Hash.new { |hash, key| hash[key] = {} }
    scope.includes(:requests).find_each do |book|
      work_ids_for(book).each do |unified_work_id|
        lookup[unified_work_id][book.book_type] = book

        source, source_id = parse_work_id(unified_work_id)
        lookup[source_id][book.book_type] = book if source == "openlibrary"
      end
    end

    lookup
  end

  def self.work_ids_for(book)
    [
      ("hardcover:#{book.hardcover_id}" if book.hardcover_id.present?),
      ("google_books:#{book.google_books_id}" if book.google_books_id.present?),
      ("openlibrary:#{book.open_library_work_id}" if book.open_library_work_id.present?)
    ].compact
  end

  # Find or initialize a book by work_id and book_type
  def self.find_or_initialize_by_work_id(work_id, book_type:)
    source, source_id = parse_work_id(work_id)
    case source
    when "hardcover"
      find_or_initialize_by(hardcover_id: source_id, book_type: book_type)
    when "google_books"
      find_or_initialize_by(google_books_id: source_id, book_type: book_type)
    else
      find_or_initialize_by(open_library_work_id: source_id, book_type: book_type)
    end
  end

  def assign_work_id(work_id)
    source, source_id = self.class.parse_work_id(work_id)
    return if source_id.blank?

    case source
    when "hardcover"
      self.hardcover_id ||= source_id
    when "google_books"
      self.google_books_id ||= source_id
    else
      self.open_library_work_id ||= source_id
    end
  end
end
