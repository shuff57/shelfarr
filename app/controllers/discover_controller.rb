# frozen_string_literal: true

class DiscoverController < ApplicationController
  def index
    @recommendations = RecommendationsService.call(Current.user)
    @existing_books_lookup = Book.preload_by_work_ids(
      @recommendations.flat_map { |candidate| candidate.sources.filter_map { |source| source[:work_id] } }
    )
    @metadata_available = MetadataService.available?
  end
end
