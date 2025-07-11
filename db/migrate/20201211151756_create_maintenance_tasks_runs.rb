# frozen_string_literal: true

class CreateMaintenanceTasksRuns < ActiveRecord::Migration[7.0]
  def change
    create_table(:maintenance_tasks_runs, id: primary_key_type) do |t|
      t.string(:task_name, null: false)
      t.datetime(:started_at)
      t.datetime(:ended_at)
      t.float(:time_running, default: 0.0, null: false)
      t.integer(:tick_count, default: 0, null: false)
      t.integer(:tick_total)
      t.string(:job_id)
      t.bigint(:cursor)
      t.string(:status, default: :enqueued, null: false)
      t.string(:error_class)
      t.string(:error_message)
      t.text(:backtrace)
      t.timestamps
      t.index(:task_name)
      t.index([:task_name, :created_at], order: { created_at: :desc })
    end
  end

  private

  def primary_key_type
    config = Rails.configuration.generators
    setting = config.options[config.orm][:primary_key_type]
    setting || :primary_key
  end
end
