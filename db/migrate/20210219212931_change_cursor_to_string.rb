# frozen_string_literal: true

class ChangeCursorToString < ActiveRecord::Migration[7.0]
  # This migration will clear all existing data in the cursor column with MySQL.
  # Ensure no Tasks are paused when this migration is deployed, or they will be resumed from the start.
  # Running tasks are able to gracefully handle this change, even if interrupted.
  def up
    change_table(:maintenance_tasks_runs) do |t|
      t.change(:cursor, :string)
    end
  end

  def down
    change_table(:maintenance_tasks_runs) do |t|
      t.change(:cursor, :bigint)
    end
  end
end
