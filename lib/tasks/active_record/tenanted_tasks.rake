# frozen_string_literal: true

# Ensure a default tenant is set for database tasks that may need it.
desc "Set the current tenant to ARTENANT if present, else the environment default"
task "db:tenant" => "load_config" do
  unless ActiveRecord::Tenanted.connection_class
    warn "ActiveRecord::Tenanted integration is not configured via connection_class"
    next
  end

  config = ActiveRecord::Tenanted.connection_class.connection_pool.db_config
  ActiveRecord::Tenanted::DatabaseTasks.new(config).set_current_tenant
end
task "db:fixtures:load" => "db:tenant"
task "db:seed"          => "db:tenant"

# Create tenanted rake tasks
tenanted_base_configs = ActiveRecord::Tenanted.base_configs(
  ActiveRecord::DatabaseConfigurations.new(ActiveRecord::Tasks::DatabaseTasks.setup_initial_database_yaml)
)
tenanted_base_configs.each do |config|
  ActiveRecord::Tenanted::DatabaseTasks.new(config).register_rake_tasks
end
ActiveRecord::Tenanted::DatabaseTasks.wrap_rails_rollback_task(tenanted_base_configs)
