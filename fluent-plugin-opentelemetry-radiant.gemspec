# frozen_string_literal: true

require_relative "lib/fluent/plugin/opentelemetry_radiant/version"

Gem::Specification.new do |gem|
  gem.name = "fluent-plugin-opentelemetry-radiant"
  gem.version = Fluent::Plugin::OpentelemetryRadiant::VERSION
  gem.authors = ["Radiant Logic, Inc."]
  gem.email = ["support@radiantlogic.com"]
  gem.summary = "Fluentd OpenTelemetry relay and ordinary-record OTLP logs output"
  gem.description = "A fork of fluent-plugin-opentelemetry 0.4.0 that retains OTLP relay and input behavior " \
                    "while converting ordinary Fluentd records into batched OTLP log requests."
  gem.homepage = "https://github.com/gnanirahulnutakki/fluent-plugin-opentelemetry-radiant"
  gem.licenses = ["Apache-2.0"]

  gem.metadata = {
    "bug_tracker_uri" => "https://github.com/gnanirahulnutakki/fluent-plugin-opentelemetry-radiant/issues",
    "source_code_uri" => "https://github.com/gnanirahulnutakki/fluent-plugin-opentelemetry-radiant",
    "rubygems_mfa_required" => "true"
  }

  gem.files = Dir["lib/**/*.rb", "CHANGELOG.md", "LICENSE", "NOTICE", "README.md"]
  gem.require_paths = ["lib"]
  gem.required_ruby_version = ">= 3.1.0"

  gem.add_runtime_dependency "async-http", "~> 0.88"
  gem.add_runtime_dependency "excon", "~> 1.2"
  gem.add_runtime_dependency "fluentd", "~> 1.18"
  gem.add_runtime_dependency "google-protobuf", "~> 4.30"

  gem.add_development_dependency "bundler", [">= 2", "< 3"]
  gem.add_development_dependency "rake", "~> 13.0"
  gem.add_development_dependency "test-unit", "~> 3.6"
  gem.add_development_dependency "grpc", "~> 1.76"
end
