# frozen_string_literal: true

module Maintenance
  # A task that uses a plain Ruby array collection to test that non-ActiveRecord collections are not supported for concurrency
  class ArrayCollectionTask < MaintenanceTasks::Task
    def collection
      [1, 2, 3]
    end

    def process(item)
      # This method won't actually be called in tests since concurrency should be rejected
      # But it's here for completeness
    end
  end
end
