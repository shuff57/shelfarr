# frozen_string_literal: true

class ImportListsController < ApplicationController
  before_action :set_import_list, only: [ :edit, :update, :destroy, :sync ]

  def index
    @import_lists = Current.user.import_lists.order(:name)
  end

  def new
    @import_list = Current.user.import_lists.new(book_type: :ebook, list_type: "query")
  end

  def create
    @import_list = Current.user.import_lists.new(import_list_params)

    if @import_list.save
      ImportListSyncJob.perform_later(@import_list.id) if @import_list.enabled?
      redirect_to import_lists_path, notice: "Import list '#{@import_list.name}' created and syncing."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit; end

  def update
    if @import_list.update(import_list_params)
      redirect_to import_lists_path, notice: "Import list updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @import_list.destroy
    redirect_to import_lists_path, notice: "Import list deleted."
  end

  def sync
    ImportListSyncJob.perform_later(@import_list.id)
    redirect_to import_lists_path, notice: "Syncing '#{@import_list.name}' now."
  end

  private

  def set_import_list
    @import_list = Current.user.import_lists.find(params[:id])
  end

  def import_list_params
    params.require(:import_list).permit(
      :name, :list_type, :source_url, :source_id, :book_type, :auto_request, :enabled, :item_limit
    )
  end
end
