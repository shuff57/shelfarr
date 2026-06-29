# frozen_string_literal: true

# Streams a book's primary file to the client, confined to the configured
# libraries. Shared by the in-browser reader (inline) and OPDS (attachment) so
# the path safety and content-type mapping live in one place.
module BookFileStreaming
  extend ActiveSupport::Concern

  private

  def send_book_file(book, disposition:)
    path = book.primary_file

    head :not_found and return if path.blank? || !File.file?(path)
    head :forbidden and return unless book_path_allowed?(path)

    send_file path, disposition: disposition, type: Book.content_type_for_path(path)
  end

  # The path is resolved server-side from Book#primary_file (never a param); this
  # is defence in depth confirming it sits inside a configured library.
  def book_path_allowed?(path)
    expanded = File.expand_path(path)

    [ SettingsService.get(:audiobook_output_path), SettingsService.get(:ebook_output_path) ]
      .compact_blank
      .any? do |allowed|
        root = File.expand_path(allowed)
        expanded == root || expanded.start_with?("#{root}/")
      end
  end
end
