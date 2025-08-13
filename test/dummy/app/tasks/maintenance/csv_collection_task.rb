# frozen_string_literal: true

module Maintenance
  # A task that uses CSV collection to test that CSV collections are not supported for concurrency
  class CsvCollectionTask < MaintenanceTasks::Task
    def collection
      require "csv"
      CSV.new("id,name\n1,test")
    end

    def process(row)
      # This method won't actually be called in tests since concurrency should be rejected
      # But it's here for completeness
    end
  end
end
