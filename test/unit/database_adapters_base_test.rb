# frozen_string_literal: true

require "test_helper"

describe ActiveRecord::Tenanted::DatabaseAdapters::Base do
  let(:adapter_class) do
    Class.new(ActiveRecord::Tenanted::DatabaseAdapters::Base) do
      def valid_tenant_name?(tenant_name)
        tenant_name == "foo"
      end
    end
  end
  let(:adapter) { adapter_class.new(Object.new) }

  test "keeps the database configuration it is given" do
    db_config = Object.new

    assert_same(db_config, adapter_class.new(db_config).db_config)
  end

  describe "#valid_tenant_name?" do
    # NotImplementedError is a ScriptError, which a plain rescue does not catch.
    test "raises a RuntimeError when the subclass does not define it" do
      error = assert_raises(RuntimeError) do
        ActiveRecord::Tenanted::DatabaseAdapters::Base.new(Object.new).valid_tenant_name?("foo")
      end

      assert_includes(error.message, "valid_tenant_name?")
    end
  end

  describe "#validate_tenant_name" do
    test "accepts a name the adapter says is valid" do
      assert_nothing_raised { adapter.validate_tenant_name("foo") }
    end

    test "raises BadTenantNameError on a name the adapter says is invalid" do
      error = assert_raises(ActiveRecord::Tenanted::BadTenantNameError) do
        adapter.validate_tenant_name("bar")
      end

      assert_includes(error.message, "\"bar\"")
    end

    test "raises with the message the adapter gives" do
      adapter_class.class_eval do
        private def tenant_name_message(tenant_name) = "only foo, not #{tenant_name}"
      end

      error = assert_raises(ActiveRecord::Tenanted::BadTenantNameError) do
        adapter.validate_tenant_name("bar")
      end

      assert_equal("only foo, not bar", error.message)
    end
  end

  test "is the superclass of every registered adapter" do
    [ ActiveRecord::Tenanted::DatabaseAdapters::SQLite,
      ActiveRecord::Tenanted::DatabaseAdapters::MySQL,
      ActiveRecord::Tenanted::DatabaseAdapters::PostgreSQL ].each do |klass|
      assert_operator(klass, :<, ActiveRecord::Tenanted::DatabaseAdapters::Base)
    end
  end
end
