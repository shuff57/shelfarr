# frozen_string_literal: true

module Opds
  # OPDS 1.2 catalog so external readers (Boox, KOReader, etc.) can browse and
  # download the library. Session cookies do not apply to those clients, so this
  # uses HTTP Basic against the User model instead.
  # ponytail: basic auth, fine on a LAN; add token auth / HTTPS if ever exposed.
  class CatalogController < ApplicationController
    include BookFileStreaming

    allow_unauthenticated_access
    before_action :authenticate_opds!

    rescue_from(ActiveRecord::RecordNotFound) { head :not_found }

    NAVIGATION_TYPE = "application/atom+xml;profile=opds-catalog;kind=navigation"
    ACQUISITION_TYPE = "application/atom+xml;profile=opds-catalog;kind=acquisition"

    def root
      render formats: [ :atom ], content_type: NAVIGATION_TYPE
    end

    def books
      @books = Book.acquired.ebooks.order(:title)
      render formats: [ :atom ], content_type: ACQUISITION_TYPE
    end

    def download
      send_book_file(Book.acquired.ebooks.find(params[:id]), disposition: "attachment")
    end

    private

    def authenticate_opds!
      authenticate_or_request_with_http_basic("Shelfarr") do |username, password|
        user = User.active.find_by(username: username)
        user.present? && user.authenticate(password)
      end
    end
  end
end
