nav_type = "application/atom+xml;profile=opds-catalog;kind=navigation"
acq_type = "application/atom+xml;profile=opds-catalog;kind=acquisition"

xml.instruct! :xml, version: "1.0", encoding: "UTF-8"
xml.feed("xmlns" => "http://www.w3.org/2005/Atom",
         "xmlns:opds" => "http://opds-spec.org/2010/catalog",
         "xmlns:dc" => "http://purl.org/dc/terms/") do
  xml.id opds_books_url
  xml.title "Shelfarr — All Books"
  xml.updated Time.current.iso8601
  xml.link(rel: "self", href: opds_books_path, type: acq_type)
  xml.link(rel: "start", href: opds_root_path, type: nav_type)

  @books.each do |book|
    xml.entry do
      xml.id "urn:shelfarr:book:#{book.id}"
      xml.title book.title
      xml.author { xml.name book.author } if book.author.present?
      xml.updated book.updated_at.iso8601
      xml.content(book.display_name, type: "text")
      xml.link(rel: "http://opds-spec.org/acquisition",
               href: opds_book_download_path(book),
               type: book.content_type)
      if book.cover_url.present?
        xml.link(rel: "http://opds-spec.org/image", href: book.cover_url)
      end
    end
  end
end
