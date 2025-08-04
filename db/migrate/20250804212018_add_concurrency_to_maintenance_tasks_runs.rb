# frozen_string_literal: true

class AddConcurrencyToMaintenanceTasksRuns < ActiveRecord::Migration[7.0]
  def change
    add_column(:maintenance_tasks_runs, :parent_run_id, :bigint, null: true)
    add_column(:maintenance_tasks_runs, :concurrency_level, :integer, null: true)
    add_column(:maintenance_tasks_runs, :end_cursor, :string, null: true)
    add_column(:maintenance_tasks_runs, :partition_index, :integer, null: true)

    add_index(:maintenance_tasks_runs, :parent_run_id)
    add_index(
      :maintenance_tasks_runs,
      [:parent_run_id, :partition_index],
      unique: true,
      name: "index_mt_runs_on_parent_run_id_and_partition_index",
    )

    add_foreign_key(
      :maintenance_tasks_runs,
      :maintenance_tasks_runs,
      column: :parent_run_id,
      primary_key: :id,
      on_delete: :cascade,
    )
  end
end
