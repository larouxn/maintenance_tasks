# frozen_string_literal: true

source "https://rubygems.org"

gemspec

gem "better_html"
gem "debug"
gem "puma"
if !@rails_gem_requirement
  gem "rails", ">= 7.1"
  ruby ">= 3.2.0"
else
  # causes Dependabot to ignore the next line and update the previous gem "rails"
  rails = "rails"
  gem rails, @rails_gem_requirement
end
gem "rubocop"
gem "rubocop-shopify"
gem "sprockets-rails"
gem "sqlite3"
gem "yard"

group :test do
  gem "capybara"
  gem "capybara-lockstep"
  # Rails main and 8.1.2 onward require Minitest 6.
  # Rails 8.0, 7.2, and 7.1 lack support for Minitest 6.
  # TODO: Remove Rails 8.0 from unspported group once a release with the following is cut.
  # https://github.com/rails/rails/commit/ec62932ee7d31e0ef870e61c2d7de2c3efe3faa6
  if @rails_gem_requirement.is_a?(String) &&
      @rails_gem_requirement.start_with?("~> 7.1", "~> 7.2", "~> 8.0")
    gem "minitest", "< 6"
  else
    # causes Dependabot to ignore the next line and update the previous gem "minitest"
    minitest = "minitest"
    gem minitest, "~> 6.0"
  end
  gem "mocha"
  gem "selenium-webdriver"
end
