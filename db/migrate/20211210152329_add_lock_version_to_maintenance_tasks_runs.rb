# frozen_string_literal: true

class AddLockVersionToMaintenanceTasksRuns < ActiveRecord::Migration[7.0]
  def change
    add_column(
      :maintenance_tasks_runs,
      :lock_version,
      :integer,
      default: 0,
      null: false,
    )
  end
end
