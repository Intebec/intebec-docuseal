# frozen_string_literal: true

# =============================================================================
# Whitelabel — Centralised brand config + licence enforcement
# =============================================================================
#
# Config loading priority:
#   1. Local YAML file  → if present, used as-is  (dev / custom deploys)
#   2. Remote API fetch → if no file, calls Intebec Dashboard  (production)
#   3. Empty defaults   → test environment only
#
# All accessors use dig() with safe fallbacks so the app never crashes on
# missing keys.  Without a valid config source the fallbacks return plain
# upstream DocuSeal values — your branding only appears with YOUR config.
#
# Local config file resolution (first match wins):
#   1. INTEBEC_CONFIG_PATH        — explicit absolute path.  PRODUCTION uses
#                                   this (docker mounts the client config at
#                                   /run/secrets/config.yml).
#   2. INTEBEC_CLIENT=<name>      — loads config/clients/<name>.yml.  Lets you
#                                   keep one file per client and switch between
#                                   them in development without editing paths.
#   3. dev / test default         — config/config.yml  (a gitignored file, or a
#                                   symlink managed by `bin/use-client`).
#   4. otherwise                  — /run/secrets/config.yml  (prod default).
#
# Per-client configs live in config/clients/*.yml and are gitignored so client
# branding never lands in version control.  See config/config.example.yml for a
# fully documented template and config/clients/README.md for the workflow.
#
# Env vars:
#   INTEBEC_CONFIG_PATH   — explicit local file path  (highest priority)
#   INTEBEC_CLIENT        — name of a config/clients/<name>.yml file  (dev)
#   INTEBEC_LICENCE_KEY   — licence UUID  (required for API mode)
#   INTEBEC_SECRET_KEY    — HMAC shared secret  (required for API mode)
#   INTEBEC_DASHBOARD_URL — override Dashboard URL  (default: https://dashboard.intebec.ca)
# =============================================================================

require 'yaml'
require 'uri'
require 'json'
require 'openssl'
require 'net/http'
require 'securerandom'
require_relative 'whitelabel/config_validator'

module Whitelabel
  class ConfigError < StandardError; end
  class LicenceRevokedError < ConfigError; end

  # Default location for a mounted/secret config in production.
  DEFAULT_CONFIG_PATH = '/run/secrets/config.yml'

  DASHBOARD_URL    = ENV.fetch('INTEBEC_DASHBOARD_URL', 'https://dashboard.intebec.ca').freeze
  CONFIG_ENDPOINT  = '/api/licences/config'
  API_TIMEOUT      = 10
  API_MAX_RETRIES  = 3
  API_RETRY_DELAY  = 2          # seconds, doubles each retry
  REFRESH_INTERVAL = 24 * 3600  # 24 h
  REFRESH_ON_ERROR = 5 * 60     # 5 min retry on transient failure

  THEME_DEFAULTS = {
    'primary' => '216 77% 52%',
    'primary_focus' => '216 77% 44%',
    'primary_content' => '0 0% 100%',
    'secondary' => '220 12% 45%',
    'secondary_focus' => '220 14% 36%',
    'secondary_content' => '0 0% 100%',
    'accent' => '160 50% 40%',
    'accent_focus' => '160 50% 34%',
    'accent_content' => '0 0% 100%',
    'neutral' => '220 16% 12%',
    'neutral_focus' => '220 16% 8%',
    'neutral_content' => '0 0% 100%',
    'base_100' => '0 0% 100%',
    'base_200' => '220 14% 96%',
    'base_300' => '220 12% 93%',
    'base_content' => '220 14% 10%',
    'info' => '205 80% 50%',
    'success' => '154 55% 38%',
    'warning' => '38 88% 48%',
    'error' => '0 72% 50%',
    'rounded_btn' => '1.9rem',
    'tab_border' => '2px',
    'tab_radius' => '.5rem'
  }.freeze

  DEFAULT_STYLING_VARIABLES = {
    'ib-bg' => '220 14% 98%',
    'ib-surface' => '0 0% 100%',
    'ib-surface-2' => '220 14% 96%',
    'ib-border' => '220 10% 88%',
    'ib-text' => '220 14% 10%',
    'ib-text-secondary' => '220 8% 40%',
    'ib-muted' => '220 6% 55%'
  }.freeze

  # ── Mutable state (thread-safe) ─────────────────────────────────────────
  @mutex        = Mutex.new
  @config       = nil
  @config_path  = nil
  @api_sourced  = false
  @next_refresh = Time.at(0).utc

  class << self
    # =====================================================================
    # Core
    # =====================================================================

    def config
      @config || load_config!
    end

    def reload!
      @mutex.synchronize do
        @config      = nil
        @config_path = nil
      end
      load_config!
    end

    # Resolved path of the active local config file.  Memoised; cleared by
    # reload!.  See the file header for the resolution order.
    def config_path
      @config_path ||= resolve_config_path
    end

    def config_source
      return :api  if @api_sourced
      return :test if @config && !config_path.file?

      :file
    end

    # Called per-request from ApplicationController.
    # For API-sourced configs, periodically re-fetches to confirm the
    # licence is still active and pick up any Dashboard changes.
    def ensure_valid!
      return true unless @api_sourced
      return true unless Time.now.utc >= @next_refresh

      @mutex.synchronize do
        return true unless Time.now.utc >= @next_refresh

        @config       = fetch_remote_config
        @next_refresh = Time.now.utc + REFRESH_INTERVAL
      rescue LicenceRevokedError
        # Licence actively revoked → propagate, controller returns 503
        @config = {}
        raise
      rescue ConfigError => e
        # Transient error (network, timeout) → keep existing config, retry sooner
        Rails.logger.error("[Whitelabel] Revalidation failed: #{e.message}")
        @next_refresh = Time.now.utc + REFRESH_ON_ERROR
      end
      true
    end

    # =====================================================================
    # Brand
    # =====================================================================

    def brand_name
      config.dig('brand', 'name') || 'DocuSeal'
    end

    def brand_short_name
      config.dig('brand', 'short_name') || brand_name
    end

    def tagline
      config.dig('brand', 'tagline') || ''
    end

    def description
      config.dig('brand', 'description') || ''
    end

    def page_title(signed_in: false)
      key = signed_in ? 'page_title_signed_in' : 'page_title_signed_out'
      config.dig('brand', key) || brand_name
    end

    # =====================================================================
    # URLs
    # =====================================================================

    def website_url
      config.dig('urls', 'website') || 'https://www.docuseal.com'
    end

    def support_email
      config.dig('urls', 'support_email') || 'support@docuseal.com'
    end

    def privacy_policy_url
      config.dig('urls', 'privacy_policy')
    end

    def terms_url
      config.dig('urls', 'terms_of_service')
    end

    def twitter_url
      config.dig('urls', 'twitter_url')
    end

    def twitter_handle
      config.dig('urls', 'twitter_handle')
    end

    def github_url
      config.dig('urls', 'github_url')
    end

    def discord_url
      config.dig('urls', 'discord_url')
    end

    # =====================================================================
    # Email
    # =====================================================================

    def email_from
      name = config.dig('email', 'from_name') || brand_name
      addr = config.dig('email', 'from_address') || support_email
      "#{name} <#{addr}>"
    end

    def email_attribution_html
      # rubocop:disable Style/FormatStringToken -- Rails i18n-style %{} tokens substituted via gsub
      raw = config.dig('email', 'attribution_html') ||
            'Sent with <a href="%{website}">%{brand}</a>.'
      raw.gsub('%{brand}', brand_name).gsub('%{website}', website_url)
      # rubocop:enable Style/FormatStringToken
    end

    # =====================================================================
    # Assets
    # =====================================================================

    def logo_path
      config.dig('assets', 'logo_path') || '/logo.svg'
    end

    def logo_width
      config.dig('assets', 'logo_width') || 37
    end

    def logo_height
      config.dig('assets', 'logo_height') || 37
    end

    def favicon_svg
      config.dig('assets', 'favicon_svg') || '/favicon.svg'
    end

    def favicon_ico
      config.dig('assets', 'favicon_ico') || '/favicon.ico'
    end

    # rubocop:disable Naming/VariableNumber -- method names mirror the standard favicon pixel sizes
    def favicon_16
      config.dig('assets', 'favicon_16') || '/favicon-16x16.png'
    end

    def favicon_32
      config.dig('assets', 'favicon_32') || '/favicon-32x32.png'
    end

    def favicon_96
      config.dig('assets', 'favicon_96') || '/favicon-96x96.png'
    end
    # rubocop:enable Naming/VariableNumber

    def apple_touch_icon
      config.dig('assets', 'apple_touch_icon') || '/apple-icon-180x180.png'
    end

    def preview_image
      config.dig('assets', 'preview_image') || '/preview.png'
    end

    # =====================================================================
    # Theme — HSL triplets for DaisyUI / CSS custom properties
    # =====================================================================

    def theme(key)
      config.dig('theme', key.to_s) || THEME_DEFAULTS[key.to_s] || '0 0% 50%'
    end

    # =====================================================================
    # PDF / Audit trail
    # =====================================================================

    def sign_reason(name)
      # rubocop:disable Style/FormatStringToken -- Rails i18n-style %{} token substituted via gsub
      template = config.dig('pdf', 'sign_reason') || 'Signed by %{name}'
      template.gsub('%{name}', name.to_s)
      # rubocop:enable Style/FormatStringToken
    end

    def audit_trail_footer
      config.dig('pdf', 'audit_trail_footer') || "Signed with #{brand_name}"
    end

    def pdf_creator
      creator = config.dig('pdf', 'creator') || brand_name
      "#{creator} (#{website_url})"
    end

    def cert_name
      config.dig('pdf', 'cert_name') || 'docuseal_aatl'
    end

    # =====================================================================
    # PWA
    # =====================================================================

    def pwa_description
      config.dig('pwa', 'description') || description
    end

    def pwa_theme_color
      config.dig('pwa', 'theme_color') || '#FFFFFF'
    end

    def pwa_background_color
      config.dig('pwa', 'background_color') || '#FFFFFF'
    end

    # =====================================================================
    # Webhooks
    # =====================================================================

    def webhook_user_agent
      config.dig('webhooks', 'user_agent') || "#{brand_name} Webhook"
    end

    # =====================================================================
    # Feature flags
    # =====================================================================

    def show_github_button?
      dig_bool('features', 'show_github_button')
    end

    def show_powered_by?
      dig_bool('features', 'show_powered_by')
    end

    def powered_by_text
      config.dig('features', 'powered_by_text') || brand_name
    end

    def show_ai_link?
      dig_bool('features', 'show_ai_link')
    end

    def show_discord_link?
      dig_bool('features', 'show_discord_link')
    end

    def show_pro_upsells?
      dig_bool('features', 'show_pro_upsells')
    end

    # =====================================================================
    # Roles & Permissions (config-driven)
    # =====================================================================
    #
    # Config format:
    #   roles:
    #     admin:
    #       permissions:
    #         templates:   [read, create, update, delete]
    #         submissions: [read, create, update, delete]
    #         users:       [read, create, update, delete]
    #         settings:    [read, create, update, delete]
    #     gestionnaire:
    #       permissions:
    #         templates:   [read, create, update, delete]
    #         submissions: [read, create, update, delete]
    #         users:       [read]
    #         settings:    [read]
    #     user:
    #       permissions:
    #         templates:   [read]
    #         submissions: [read]
    #

    # Default permission matrix — used when no roles section in config.
    DEFAULT_ROLES = {
      'admin' => {
        'permissions' => {
          'templates' => %w[read create update delete],
          'submissions' => %w[read create update delete],
          'users' => %w[read create update delete],
          'settings' => %w[read create update delete]
        }
      },
      'gestionnaire' => {
        'permissions' => {
          'templates' => %w[read create update delete],
          'submissions' => %w[read create update delete],
          'users' => %w[read],
          'settings' => %w[read]
        }
      },
      'user' => {
        'permissions' => {
          'templates' => %w[read],
          'submissions' => %w[read],
          'users' => [],
          'settings' => []
        }
      }
    }.freeze

    # All available roles (keys).  Order matters — first is the default.
    def roles
      (config['roles'] || DEFAULT_ROLES).keys
    end

    # The default role assigned to new users.
    def default_role
      roles.first
    end

    # Full role definition hash for a given role slug.
    def role_definition(role_slug)
      all = config['roles'] || DEFAULT_ROLES
      all[role_slug.to_s] || {}
    end

    # Permission list for a role + resource.
    # Returns e.g. ["read", "create", "update"] or [].
    def role_permissions(role_slug, resource)
      perms = role_definition(role_slug).dig('permissions', resource.to_s)
      perms.is_a?(Array) ? perms : []
    end

    # Check if a role has a specific action on a resource.
    def role_can?(role_slug, resource, action)
      role_permissions(role_slug, resource).include?(action.to_s)
    end

    # Check if a role is an admin (first role in the list is always the admin).
    def admin_role?(role_slug)
      role_slug.to_s == roles.first
    end

    # Validate that a role slug exists in config.
    def role_valid?(role_slug)
      roles.include?(role_slug.to_s)
    end

    # Returns the rank index of a role (0 = highest privilege = admin).
    # Unknown roles return roles.size (treated as lowest).
    def role_rank(role_slug)
      roles.index(role_slug.to_s) || roles.size
    end

    # Returns only roles that the given actor_role can assign/manage.
    # An actor can only work with roles at their own rank or lower (higher index).
    def manageable_roles(actor_role)
      rank = role_rank(actor_role.to_s)
      roles[rank..]
    end

    # All known settings sections in display order.
    ALL_SETTINGS_SECTIONS = %w[account email storage notifications esign personalization users api webhooks].freeze

    # Returns true if the role is allowed to see the given settings section.
    # Falls back to ALL_SETTINGS_SECTIONS for roles that have settings read
    # permission but no explicit sections list (backward-compatible).
    def setting_section_visible?(role_slug, section)
      defn = role_definition(role_slug)
      sections = defn['settings_sections']

      if sections.is_a?(Array)
        sections.map(&:to_s).include?(section.to_s)
      else
        # No explicit list → grant all sections to roles that can read settings.
        role_permissions(role_slug, 'settings').include?('read')
      end
    end

    # =====================================================================
    # Internal
    # =====================================================================

    def temp_email_domain
      config.dig('internal', 'temp_email_domain') || 'docuseal.com'
    end

    # =====================================================================
    # Locale / Translations
    # =====================================================================

    def default_locale
      config.dig('locale', 'default') || 'en'
    end

    def available_locales
      config.dig('locale', 'available') || %w[en]
    end

    def fallback_locale
      config.dig('locale', 'fallback') || 'en'
    end

    def translation_overrides
      config.dig('text', 'translations') || {}
    end

    # =====================================================================
    # Styling
    # =====================================================================

    def styling_variables
      DEFAULT_STYLING_VARIABLES.merge(config.dig('styling', 'css_variables') || {})
    end

    # rubocop:disable Metrics/MethodLength, Naming/VariableNumber
    def inline_css_variables
      vars = {
        'wl-ib-primary' => theme(:primary),
        'wl-ib-primary-strong' => theme(:primary_focus),
        'wl-ib-primary-soft' => "#{theme(:primary)} / 0.12",
        'wl-ib-neutral' => theme(:neutral),
        'wl-ib-neutral-soft' => theme(:base_200),
        'wl-p' => theme(:primary),
        'wl-pf' => theme(:primary_focus),
        'wl-pc' => theme(:primary_content),
        'wl-s' => theme(:secondary),
        'wl-sf' => theme(:secondary_focus),
        'wl-sc' => theme(:secondary_content),
        'wl-a' => theme(:accent),
        'wl-af' => theme(:accent_focus),
        'wl-ac' => theme(:accent_content),
        'wl-n' => theme(:neutral),
        'wl-nf' => theme(:neutral_focus),
        'wl-nc' => theme(:neutral_content),
        'wl-b1' => theme(:base_100),
        'wl-b2' => theme(:base_200),
        'wl-b3' => theme(:base_300),
        'wl-bc' => theme(:base_content),
        'wl-in' => theme(:info),
        'wl-su' => theme(:success),
        'wl-wa' => theme(:warning),
        'wl-er' => theme(:error),
        'wl-rounded-btn' => theme(:rounded_btn)
      }

      styling_variables.each { |key, value| vars["wl-#{key}"] = value }

      declarations = vars.map { |k, v| "--#{k}: #{v};" }.join(' ')
      ":root { #{declarations} }"
    end
    # rubocop:enable Metrics/MethodLength, Naming/VariableNumber

    # =====================================================================
    # Validation
    # =====================================================================

    # Validate a config hash. Returns { errors: [...], warnings: [...] }.
    # See Whitelabel::ConfigValidator for the rules.
    def validate(raw = config)
      ConfigValidator.validate(raw)
    end

    # =====================================================================
    # Config signature (file-based only)
    # =====================================================================

    def enforce_config_signature?
      dig_bool('security', 'enforce_config_signature')
    end

    def config_signature
      config.dig('security', 'config_signature') || ''
    end

    def signature_payload
      canonical_payload(config)
    end

    def generate_config_signature(secret)
      raise ConfigError, 'Secret required' if secret.to_s.empty?

      OpenSSL::HMAC.hexdigest('SHA256', secret, signature_payload).downcase
    end

    private

    # =====================================================================
    # Config loading
    # =====================================================================

    def load_config!
      @mutex.synchronize do
        return @config if @config # another thread beat us

        if config_path.file?
          load_from_file!
        elsif Rails.env.test?
          load_test_defaults!
        else
          load_from_api!
        end
      end
      @config
    end

    # Resolve which local YAML file to load.  First match wins:
    #   1. INTEBEC_CONFIG_PATH  (explicit path — production / docker)
    #   2. INTEBEC_CLIENT       (config/clients/<name>.yml — dev switching)
    #   3. config/config.yml    (dev / test default — symlink or local file)
    #   4. /run/secrets/config.yml (prod default)
    def resolve_config_path
      explicit = ENV['INTEBEC_CONFIG_PATH'].to_s.strip
      return Pathname.new(explicit) unless explicit.empty?

      client = ENV['INTEBEC_CLIENT'].to_s.strip
      return clients_dir.join("#{client}.yml") unless client.empty?

      if defined?(Rails) && Rails.respond_to?(:env) && (Rails.env.development? || Rails.env.test?)
        return app_root.join('config', 'config.yml')
      end

      Pathname.new(DEFAULT_CONFIG_PATH)
    end

    # Directory holding per-client config files (config/clients/<name>.yml).
    # Resolution (first wins):
    #   1. INTEBEC_CLIENTS_DIR env var (explicit override; relative => app root)
    #   2. config/whitelabel/clients  (private submodule, auto-detected)
    #   3. config/clients             (in-repo default)
    # Auto-detection means a populated submodule "just works" with no env var,
    # so colleagues don't each have to export anything.
    def clients_dir
      custom = ENV['INTEBEC_CLIENTS_DIR'].to_s.strip
      unless custom.empty?
        path = Pathname.new(custom)
        return path.absolute? ? path : app_root.join(custom)
      end

      submodule = app_root.join('config', 'whitelabel', 'clients')
      return submodule if submodule.directory?

      app_root.join('config', 'clients')
    end

    def app_root
      if defined?(Rails) && Rails.respond_to?(:root) && Rails.root
        Rails.root
      else
        Pathname.new(File.expand_path('..', __dir__))
      end
    end

    def load_from_file!
      path = config_path
      raw = YAML.safe_load_file(
        path,
        permitted_classes: [], permitted_symbols: [], aliases: false
      )
      raise ConfigError, '[Whitelabel] Config must be a YAML mapping' unless raw.is_a?(Hash)

      verify_file_signature!(raw)
      validate_loaded!(raw, path)
      @config      = raw
      @api_sourced = false
      Rails.logger.info("[Whitelabel] Loaded config from file: #{path}")
    rescue Psych::SyntaxError => e
      raise ConfigError, "[Whitelabel] YAML parse error in #{path}: #{e.message}"
    rescue Errno::EISDIR
      raise ConfigError, "[Whitelabel] #{path} is a directory, not a file."
    end

    def load_from_api!
      licence_key = ENV['INTEBEC_LICENCE_KEY'].to_s
      secret_key  = ENV['INTEBEC_SECRET_KEY'].to_s

      if licence_key.empty? || secret_key.empty?
        raise ConfigError,
              '[Whitelabel] No config file found and INTEBEC_LICENCE_KEY / INTEBEC_SECRET_KEY ' \
              'env vars are missing. Cannot start without a config source.'
      end

      @config       = fetch_remote_config
      @api_sourced  = true
      @next_refresh = Time.now.utc + REFRESH_INTERVAL
      Rails.logger.info('[Whitelabel] Loaded config from Intebec Dashboard API')
    end

    def load_test_defaults!
      @config      = {}
      @api_sourced = false
      Rails.logger.info('[Whitelabel] Test mode — all accessors return safe fallbacks')
    end

    # =====================================================================
    # Remote config fetch (with retry)
    # =====================================================================

    # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/BlockLength
    def fetch_remote_config
      licence_key = ENV.fetch('INTEBEC_LICENCE_KEY')
      secret_key  = ENV.fetch('INTEBEC_SECRET_KEY')
      last_error  = nil

      API_MAX_RETRIES.times do |attempt|
        uri         = URI.join(DASHBOARD_URL, CONFIG_ENDPOINT)
        timestamp   = Time.now.utc.to_i.to_s
        nonce       = SecureRandom.hex(12)
        instance_id = stable_instance_id
        payload     = [licence_key, timestamp, nonce, instance_id].join('.')
        signature   = OpenSSL::HMAC.hexdigest('SHA256', secret_key, payload)

        uri.query = URI.encode_www_form(licence_key: licence_key, instance_id: instance_id)

        req = Net::HTTP::Get.new(uri)
        req['Accept']              = 'application/json'
        req['X-Licence-Key']       = licence_key
        req['X-Licence-Timestamp'] = timestamp
        req['X-Licence-Nonce']     = nonce
        req['X-Licence-Signature'] = signature
        req['X-Licence-Instance']  = instance_id
        req['User-Agent']          = 'Intebec-DocuSeal'

        resp = Net::HTTP.start(
          uri.host, uri.port,
          use_ssl: uri.scheme == 'https',
          open_timeout: API_TIMEOUT,
          read_timeout: API_TIMEOUT
        ) { |http| http.request(req) }

        raise ConfigError, "HTTP #{resp.code}" unless [200, 201].include?(resp.code.to_i)

        parsed = JSON.parse(resp.body)
        status = parsed['status'].to_s

        raise LicenceRevokedError, "Licence status: #{status}" unless %w[active trial].include?(status)

        remote_cfg = parsed['config']
        raise ConfigError, 'API returned no config payload' unless remote_cfg.is_a?(Hash)

        return remote_cfg
      rescue LicenceRevokedError
        raise # don't retry revocations
      rescue StandardError => e
        last_error = e.message
        delay = API_RETRY_DELAY * (2**attempt)
        if attempt < API_MAX_RETRIES - 1
          Rails.logger.warn(
            "[Whitelabel] API attempt #{attempt + 1}/#{API_MAX_RETRIES} " \
            "failed: #{e.message}, retry in #{delay}s"
          )
          sleep(delay)
        end
      end

      raise ConfigError,
            "[Whitelabel] Dashboard unreachable after #{API_MAX_RETRIES} attempts: #{last_error}"
    end
    # rubocop:enable Metrics/AbcSize, Metrics/MethodLength, Metrics/BlockLength

    def stable_instance_id
      @stable_instance_id ||= begin
        raw = [ENV.fetch('INTEBEC_LICENCE_KEY', ''), ENV.fetch('HOST', 'localhost')].join(':')
        OpenSSL::Digest::SHA256.hexdigest(raw)
      end
    end

    # =====================================================================
    # Validation (file-based loads)
    # =====================================================================
    #
    # Logs warnings/errors found in a freshly-loaded config so typos surface in
    # the boot log instead of as broken pages.  Set INTEBEC_STRICT_CONFIG=true
    # to refuse to boot on validation errors (recommended for CI / deploys).
    def validate_loaded!(raw, path)
      result = ConfigValidator.validate(raw)

      result[:warnings].each { |w| Rails.logger.warn("[Whitelabel] config warning (#{path}): #{w}") }
      result[:errors].each   { |e| Rails.logger.error("[Whitelabel] config error (#{path}): #{e}") }

      return if result[:errors].empty?
      return unless ENV['INTEBEC_STRICT_CONFIG'].to_s.strip.casecmp('true').zero?

      raise ConfigError,
            "[Whitelabel] #{result[:errors].size} config error(s) in #{path} " \
            "(INTEBEC_STRICT_CONFIG=true): #{result[:errors].join('; ')}"
    end

    # =====================================================================
    # File signature verification (optional, for file-based configs)
    # =====================================================================

    def verify_file_signature!(raw)
      return unless raw.dig('security', 'enforce_config_signature') == true

      secret = ENV['INTEBEC_SECRET_KEY'].to_s
      raise ConfigError, '[Whitelabel] INTEBEC_SECRET_KEY required for config signature verification' if secret.empty?

      expected = raw.dig('security', 'config_signature').to_s.downcase
      actual   = OpenSSL::HMAC.hexdigest('SHA256', secret, canonical_payload(raw)).downcase

      return if expected.length == 64 && secure_compare(actual, expected)

      raise ConfigError, '[Whitelabel] Config signature mismatch — refusing to boot.'
    end

    def canonical_payload(loaded)
      copy = loaded.deep_dup
      copy['security']&.delete('config_signature')
      JSON.generate(deep_sort_hash(copy))
    end

    def deep_sort_hash(value)
      case value
      when Hash
        value.keys.sort.index_with { |k| deep_sort_hash(value[k]) }
      when Array
        value.map { |v| deep_sort_hash(v) }
      else
        value
      end
    end

    def secure_compare(actual, expected)
      return false unless actual.bytesize == expected.bytesize

      ActiveSupport::SecurityUtils.secure_compare(actual, expected)
    end

    # =====================================================================
    # Helpers
    # =====================================================================

    def dig_bool(section, key, default: false)
      value = config.dig(section, key)
      value.nil? ? default : value
    end
  end
end
