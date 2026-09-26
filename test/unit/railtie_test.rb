# frozen_string_literal: true

require "test_helper"
require "open3"

describe ActiveRecord::Tenanted::Railtie do
  # A subprocess, because the test helper loads Active Storage into this one.
  test "an application that does not load Active Storage boots" do
    script = <<~RUBY
      require "bundler/setup"
      require "rails"
      require "active_record/railtie"
      require "activerecord-tenanted"

      class WithoutActiveStorage < Rails::Application
        config.eager_load = false
        config.logger = Logger.new(nil)
        config.secret_key_base = "secret"
        config.root = Dir.mktmpdir
      end

      WithoutActiveStorage.initialize!
      puts defined?(ActiveStorage::Service) ? "Active Storage loaded" : "Active Storage not loaded"
    RUBY

    output, status = Open3.capture2e(RbConfig.ruby, "-e", script, chdir: File.expand_path("../..", __dir__))

    assert_predicate status, :success?, output
    assert_includes output, "Active Storage not loaded"
  end
end
