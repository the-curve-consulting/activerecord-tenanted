# frozen_string_literal: true

module ActiveRecord
  module Tenanted
    module DatabaseAdapters # :nodoc:
      #
      #  What every database adapter shares. A subclass must define #valid_tenant_name?, and may
      #  define #tenant_name_message to say which names it accepts.
      #
      class Base
        attr_reader :db_config

        def initialize(db_config)
          @db_config = db_config
        end

        # The Active Storage disk service interpolates the tenant name into a filesystem path, so a
        # valid name must be a single, safe path segment whatever the database allows.
        #
        # This raises a RuntimeError and not NotImplementedError, which is a ScriptError, so that a
        # plain rescue catches it.
        def valid_tenant_name?(tenant_name)
          raise "#{self.class} must implement #{__method__}"
        end

        def validate_tenant_name(tenant_name)
          raise BadTenantNameError, tenant_name_message(tenant_name) unless valid_tenant_name?(tenant_name)
        end

        private
          def tenant_name_message(tenant_name)
            "Invalid tenant name: #{tenant_name.inspect}"
          end
      end
    end
  end
end
