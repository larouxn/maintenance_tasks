# frozen_string_literal: true

# Configure Rails Environment
ENV["RAILS_ENV"] = "test"

# Force Thor CLI to output on 200 columns, ignoring
# the size of the actual terminal running the tests.
ENV["THOR_COLUMNS"] = "200"

require_relative "../test/dummy/config/environment"
ActiveRecord::Migrator.migrations_paths =
  [File.expand_path("../test/dummy/db/migrate", __dir__)]
ActiveRecord::Migrator.migrations_paths <<
  File.expand_path("../db/migrate", __dir__)
require "rails/test_help"
require "mocha/minitest"

Mocha.configure do |c|
  c.display_matching_invocations_on_failure = true
  c.stubbing_method_on_non_mock_object      = :allow
  c.stubbing_method_unnecessarily           = :prevent
  c.stubbing_non_existent_method            = :prevent
  c.stubbing_non_public_method              = :prevent
end

# Filter out the backtrace from minitest while preserving the one from other
# libraries.
Minitest.backtrace_filter = Minitest::BacktraceFilter.new

# Load fixtures from the engine
if ActiveSupport::TestCase.respond_to?(:fixture_paths=)
  ActiveSupport::TestCase.fixture_paths = [File.expand_path("fixtures", __dir__)]
  ActionDispatch::IntegrationTest.fixture_paths = ActiveSupport::TestCase.fixture_paths
  ActiveSupport::TestCase.file_fixture_path = File.expand_path("fixtures", __dir__) + "/files"
  ActiveSupport::TestCase.fixtures(:all)
elsif ActiveSupport::TestCase.respond_to?(:fixture_path=)
  ActiveSupport::TestCase.fixture_path = File.expand_path("fixtures", __dir__)
  ActionDispatch::IntegrationTest.fixture_path = ActiveSupport::TestCase.fixture_path
  ActiveSupport::TestCase.file_fixture_path = ActiveSupport::TestCase.fixture_path + "/files"
  ActiveSupport::TestCase.fixtures(:all)
end

module Warning
  class << self
    def warn(message)
      # To be removed once warnings are fixed in selenium-webdriver and sprockets.
      # This is noisy, so ignoring completely for now.
      return if message.match?("URI::RFC3986_PARSER.(un)?escape is obsolete.")
      return if Rails.gem_version < "7.1" && message.match?(/the block passed to .* may be ignored/)

      raise message.to_s
    end
  end
end
$VERBOSE = true
Warning[:deprecated] = true

Maintenance::UpdatePostsTask.fast_task = true
