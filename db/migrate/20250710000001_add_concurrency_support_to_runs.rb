# frozen_string_literal: true

class AddConcurrencySupportToRuns < ActiveRecord::Migration[7.0]
  def change
    add_column :maintenance_tasks_runs, :parent_run_id, :bigint, null: true
    add_column :maintenance_tasks_runs, :concurrency_level, :integer, null: true
    add_column :maintenance_tasks_runs, :partition_start, :string, null: true
    add_column :maintenance_tasks_runs, :partition_end, :string, null: true
    add_column :maintenance_tasks_runs, :is_parent_run, :boolean, default: false, null: false
    
    add_index :maintenance_tasks_runs, :parent_run_id
    add_index :maintenance_tasks_runs, [:parent_run_id, :status]
    add_foreign_key :maintenance_tasks_runs, :maintenance_tasks_runs, column: :parent_run_id
  end
end
