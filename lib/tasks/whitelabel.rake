# frozen_string_literal: true

require_relative '../whitelabel'

namespace :whitelabel do
  desc 'Validate a single white-label config file. Usage: rake whitelabel:validate[path/to/config.yml]'
  task :validate, [:path] do |_t, args|
    path = args[:path] || ENV['CONFIG'] || Whitelabel.config_path.to_s

    abort("Config file not found: #{path}") unless File.file?(path)

    ok = validate_file(path)
    exit(ok ? 0 : 1)
  end

  desc 'Validate every config in the clients dir (INTEBEC_CLIENTS_DIR or config/clients).'
  task :lint do
    dir = Whitelabel.clients_dir
    files = Dir.glob(File.join(dir, '*.yml')).reject { |f| File.basename(f).start_with?('.') }

    if files.empty?
      puts "No client configs found in #{dir}"
      exit(0)
    end

    all_ok = files.sort.map { |f| validate_file(f) }.all?
    puts
    puts(all_ok ? "✓ All #{files.size} config(s) valid." : '✗ Some configs have errors.')
    exit(all_ok ? 0 : 1)
  end
end

# Loads a YAML file and prints its validation result. Returns true if no errors.
def validate_file(path)
  raw = YAML.safe_load_file(path, permitted_classes: [], permitted_symbols: [], aliases: false)
  result = Whitelabel::ConfigValidator.validate(raw)

  puts "── #{path}"
  result[:warnings].each { |w| puts "  ⚠ #{w}" }
  result[:errors].each   { |e| puts "  ✗ #{e}" }
  puts '  ✓ valid' if result[:warnings].empty? && result[:errors].empty?

  result[:errors].empty?
rescue Psych::SyntaxError => e
  puts "── #{path}"
  puts "  ✗ YAML parse error: #{e.message}"
  false
end
