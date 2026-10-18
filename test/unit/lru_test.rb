# frozen_string_literal: true

require "test_helper"

describe ActiveRecord::Tenanted::LRU do
  let(:lru) { ActiveRecord::Tenanted::LRU.new }

  it "stores and retrieves values" do
    assert_equal 0, lru.size

    lru[:a] = 1

    assert_equal 1, lru.size

    lru[:b] = 2

    assert_equal 2, lru.size

    lru[:c] = 3

    assert_equal 3, lru.size
    assert_equal 1, lru[:a]
    assert_equal 2, lru[:b]
    assert_equal 3, lru[:c]

    lru[:b] = 12

    assert_equal 3, lru.size
    assert_equal 1, lru[:a]
    assert_equal 12, lru[:b]
    assert_equal 3, lru[:c]
  end

  it "moves written keys to the end" do
    lru[:a] = 1
    lru[:b] = 2
    lru[:c] = 3

    assert_equal [ :a, :b, :c ], lru.keys

    lru[:b] = 12

    assert_equal [ :a, :c, :b ], lru.keys

    lru[:a] = 11

    assert_equal 3, lru.size
    assert_equal [ :c, :b, :a ], lru.keys
  end

  it "moves read keys to the end" do
    lru[:a] = 1
    lru[:b] = 2
    lru[:c] = 3

    assert_equal [ :a, :b, :c ], lru.keys

    lru[:b]

    assert_equal [ :a, :c, :b ], lru.keys

    lru[:a]

    assert_equal [ :c, :b, :a ], lru.keys
  end

  it "pops the oldest key" do
    lru[:a] = 1
    lru[:b] = 2
    lru[:c] = 3

    assert_equal [ :a, :b, :c ], lru.keys

    key, value = lru.pop

    assert_equal :a, key
    assert_equal 1, value
    assert_equal 2, lru.size
    assert_equal [ :b, :c ], lru.keys

    key, value = lru.pop

    assert_equal :b, key
    assert_equal 2, value
    assert_equal 1, lru.size
    assert_equal [ :c ], lru.keys

    key, value = lru.pop

    assert_equal :c, key
    assert_equal 3, value
    assert_equal 0, lru.size
    assert_equal [], lru.keys

    key, value = lru.pop

    assert_nil key
    assert_nil value
    assert_equal 0, lru.size
    assert_equal [], lru.keys
  end

  it "yields the oldest first without moving keys, and lets the block delete" do
    lru[:a] = 1
    lru[:b] = 2
    lru[:c] = 3

    yielded = []
    lru.each_oldest_first do |key, value|
      yielded << [ key, value ]
      lru.delete(key) if key == :b
    end

    assert_equal [ [ :a, 1 ], [ :b, 2 ], [ :c, 3 ] ], yielded
    assert_equal [ :a, :c ], lru.keys
  end
end
