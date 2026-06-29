# frozen_string_literal: true

require "test_helper"

class ReadingProgressTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
    @book = books(:audiobook_acquired)
  end

  test "is unique per user and book" do
    ReadingProgress.create!(user: @user, book: @book, location: "a", percent: 10)
    dup = ReadingProgress.new(user: @user, book: @book, location: "b", percent: 20)
    assert_not dup.valid?
  end

  test "percent must be within 0..100" do
    assert_not ReadingProgress.new(user: @user, book: @book, percent: 150).valid?
    assert_not ReadingProgress.new(user: @user, book: @book, percent: -1).valid?
    assert ReadingProgress.new(user: @user, book: @book, percent: 0).valid?
  end
end
