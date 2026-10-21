# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "production"
ENV["SECRET_KEY_BASE_DUMMY"] ||= "1"

require "erb"
require "stringio"
require "uri"
require "yaml"

# Prepare the database and dump its schema cache before booting, as a deploy
# would. With check_schema_cache_dump_version = false (set by the template), a
# production boot defines attribute methods for the models whose tables are in
# db/schema_cache.yml; without the dump, a model's first use in a request
# Ractor would have to define them. Seeding runs in the same separate process:
# using Post in this one would define its attribute methods on the main Ractor
# and hide whether the boot did.
puts "Preparing and seeding the database..."
system(File.expand_path("../bin/rails", __dir__), "db:prepare", "db:schema:cache:dump", "db:seed", exception: true)

require_relative "../config/environment"

ActionController::Base.allow_forgery_protection = false

# The ids of the posts db/seeds.rb created, without going through Post.
seed_post_id, delete_post_id = ActiveRecord::Base.with_connection do |connection|
  [ "Seed post body from Ractor test", "Delete me from Ractor test" ].map do |body|
    connection.select_value("SELECT id FROM posts WHERE body = #{connection.quote(body)}") ||
      abort("db/seeds.rb didn't create the post #{body.inspect}")
  end
end
puts "Database seeded."

REQUESTS = YAML.safe_load(
  ERB.new(File.read(File.expand_path("requests.yml.erb", __dir__))).result(binding),
  permitted_classes: [Symbol],
  aliases: true,
).freeze

PASS = []
FAIL = []

def pass(label)
  puts "  PASS  #{label}"
  PASS << label
end

def fail(label, error)
  message = "#{error.class}: #{error.message}"
  puts "  FAIL  #{label}"
  puts "        #{message}"
  error.backtrace&.first(10)&.each { |line| puts "          #{line}" }
  FAIL << { label: label, message: message }
end

def build_env(spec)
  body = spec["params"] ? URI.encode_www_form(spec["params"]) : ""

  {
    "REQUEST_METHOD" => spec["method"],
    "SCRIPT_NAME" => "",
    "PATH_INFO" => spec["path"],
    "QUERY_STRING" => spec["query"] || "",
    "SERVER_NAME" => "localhost",
    "SERVER_PORT" => "3000",
    "SERVER_PROTOCOL" => "HTTP/1.1",
    "HTTP_HOST" => "localhost:3000",
    "HTTP_ACCEPT" => "text/html",
    "HTTP_USER_AGENT" => "RactorTest",
    "CONTENT_TYPE" => spec["params"] ? "application/x-www-form-urlencoded" : nil,
    "CONTENT_LENGTH" => body.bytesize.to_s,
    "rack.version" => [1, 6],
    "rack.multithread" => true,
    "rack.multiprocess" => false,
    "rack.run_once" => false,
    "rack.url_scheme" => "http",
    "rack.body" => body,
  }.merge(spec["headers"] || {}).compact
end

# Ractorize the application the way config.ru does before serving.
def ractorize_application
  Rails.application.ractorize!

  begin
    require "i18n/ractorize"
  rescue LoadError
    # Released i18n has no Ractor support; the template pins Shopify/i18n ractor_support.
  end
end

def test_application_shareability
  label = "application is shareable"
  ractorize_application

  if Ractor.shareable?(Rails.application)
    pass(label)
  else
    fail(label, RuntimeError.new("#{Rails.application.class} is not shareable"))
  end
rescue => error
  fail(label, error)
end

def test_request(spec)
  method = spec["method"]
  path = spec["path"]
  query = spec["query"]
  label = "#{method} #{path}"
  label += " (#{query})" if query && !query.empty?

  env = build_env(spec)
  result = Ractor.new(Rails.application, env) do |app, request_env|
    request_env["rack.input"] = StringIO.new(request_env.delete("rack.body") || "")
    request_env["rack.errors"] = StringIO.new
    request_env["action_dispatch.show_exceptions"] = :none

    status, headers, body = app.call(request_env)
    response_body = +""
    body.each { |part| response_body << part }
    body.close if body.respond_to?(:close)

    { status: status, body: response_body, location: headers["location"] || headers["Location"] }
  rescue => error
    { error: "#{error.class}: #{error.message}", trace: error.backtrace&.first(5)&.join("\n") }
  end.value

  if result[:error]
    fail(label, RuntimeError.new("#{result[:error]}\n#{result[:trace]}"))
    return
  end

  expected_statuses = Array(spec["expect"])
  unless expected_statuses.include?(result[:status])
    fail(label, RuntimeError.new("Expected #{expected_statuses.join('/')}, got #{result[:status]}"))
    return
  end

  missing = Array(spec["body_includes"]).compact.reject { |text| result[:body].include?(text) }
  unless missing.empty?
    fail(label, RuntimeError.new("Response body missing #{missing.inspect}; got #{result[:body].inspect[0..300]}"))
    return
  end

  detail = "#{result[:status]} (#{result[:body].bytesize} bytes)"
  detail += " -> #{result[:location]}" if result[:location]
  pass("#{label} -> #{detail}")
rescue => error
  fail(label, error)
end

phases = ARGV.map(&:strip)
phases = %w[shareable request] if phases.empty?

puts "Ractor Safety Test"
puts "  Ruby:  #{RUBY_DESCRIPTION}"
puts "  Rails: #{Rails.version}"
puts "  Env:   #{Rails.env}"
puts "=" * 70

if phases.include?("shareable")
  puts
  puts "Phase 1: Application shareability"
  puts "-" * 50
  test_application_shareability
end

if phases.include?("request")
  puts
  puts "Phase 2: HTTP requests in Ractor"
  puts "-" * 50
  ractorize_application unless Rails.application.frozen?
  REQUESTS.each { |spec| test_request(spec) }
end

puts
puts "=" * 70
total = PASS.size + FAIL.size
puts "#{PASS.size}/#{total} passed, #{FAIL.size} failed"

if FAIL.any?
  puts
  puts "First failure to fix:"
  puts "  #{FAIL.first[:label]}"
  puts "  #{FAIL.first[:message]}"
  exit 1
end

puts
puts "All Ractor safety tests passed!"
