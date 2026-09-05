# frozen_string_literal: true

require "test_helper"

class Picoruby::Cloudflare::TemplateTest < Test::Unit::TestCase
  test "VERSION" do
    assert do
      ::Picoruby::Cloudflare::Template.const_defined?(:VERSION)
    end
  end

  test "something useful" do
    assert_equal("expected", "actual")
  end
end
