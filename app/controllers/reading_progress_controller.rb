# frozen_string_literal: true

# Per-user reading position for a book, read and written by the in-browser
# reader. Scoped to Current.user so one user's place never leaks to another.
class ReadingProgressController < ApplicationController
  rescue_from(ActiveRecord::RecordNotFound) { head :not_found }

  def show
    book = Book.acquired.find(params[:id])
    progress = Current.user.reading_progresses.find_by(book_id: book.id)

    render json: progress ? { location: progress.location, percent: progress.percent } : {}
  end

  def update
    book = Book.acquired.find(params[:id])
    progress = Current.user.reading_progresses.find_or_initialize_by(book_id: book.id)
    progress.location = params[:location]
    progress.percent = params[:percent].to_f.clamp(0, 100)

    if progress.save
      head :no_content
    else
      render json: { errors: progress.errors.full_messages }, status: :unprocessable_entity
    end
  end
end
