nav_type = "application/atom+xml;profile=opds-catalog;kind=navigation"
acq_type = "application/atom+xml;profile=opds-catalog;kind=acquisition"

xml.instruct! :xml, version: "1.0", encoding: "UTF-8"
xml.feed("xmlns" => "http://www.w3.org/2005/Atom",
         "xmlns:opds" => "http://opds-spec.org/2010/catalog") do
  xml.id opds_root_url
  xml.title "Shelfarr Library"
  xml.updated Time.current.iso8601
  xml.link(rel: "self", href: opds_root_path, type: nav_type)
  xml.link(rel: "start", href: opds_root_path, type: nav_type)

  xml.entry do
    xml.id opds_books_url
    xml.title "All Books"
    xml.updated Time.current.iso8601
    xml.link(rel: "subsection", href: opds_books_path, type: acq_type)
    xml.content("All ebooks in the Shelfarr library", type: "text")
  end
end
