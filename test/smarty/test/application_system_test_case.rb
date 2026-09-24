require "test_helper"
require "selenium/webdriver" # for the HTTP client below, which is read before driven_by loads it

Capybara.server = :puma, { Silent: true } # suppress server boot announcement

#  A CI runner is slower, and busier, than a developer machine. The webdriver then takes longer to
#  answer than the time Selenium waits for it, and a run fails with
#
#      Net::ReadTimeout with #<TCPSocket:(closed)>
#
#  which is that wait running out, and not a fault in the application under test. The waits below
#  are long enough that a slow runner does not look like a failure.
Capybara.default_max_wait_time = 10

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1400 ], options: {
    http_client: Selenium::WebDriver::Remote::Http::Default.new(open_timeout: 120, read_timeout: 120)
  }
end
