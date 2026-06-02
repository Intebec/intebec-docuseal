# frozen_string_literal: true

module Whitelabel
  # Dependency-free validator for white-label config hashes.
  #
  # Returns { errors: [String], warnings: [String] }.  Errors are structural
  # problems that will likely break the app; warnings are likely-mistakes
  # (wrong types, malformed values, unknown keys) that still let the app boot
  # on its safe fallbacks.
  #
  # Usage:
  #   Whitelabel::ConfigValidator.validate(yaml_hash)
  module ConfigValidator
    KNOWN_TOP_LEVEL = %w[
      brand urls email assets theme pdf pwa webhooks features
      internal locale styling text roles security
    ].freeze

    # Theme keys that hold an HSL triplet "H S% L%" (the rest are CSS sizes).
    HSL_THEME_KEYS = %w[
      primary primary_focus primary_content
      secondary secondary_focus secondary_content
      accent accent_focus accent_content
      neutral neutral_focus neutral_content
      base_100 base_200 base_300 base_content
      info success warning error
    ].freeze
    HSL_RE = /\A\d{1,3}\s+\d{1,3}%\s+\d{1,3}%\z/

    ASSET_KEYS = %w[
      logo_path favicon_svg favicon_ico favicon_16 favicon_32 favicon_96
      apple_touch_icon preview_image
    ].freeze

    BOOLEAN_FEATURE_KEYS = %w[
      show_github_button show_powered_by show_ai_link show_discord_link show_pro_upsells
    ].freeze

    PERMISSION_RESOURCES = %w[templates submissions users settings].freeze
    PERMISSION_ACTIONS   = %w[read create update delete].freeze
    SETTINGS_SECTIONS    = %w[account email storage notifications esign personalization users api webhooks].freeze

    module_function

    def validate(raw)
      errors = []
      warnings = []

      unless raw.is_a?(Hash)
        return { errors: ['Config root must be a YAML mapping (key: value).'], warnings: [] }
      end

      check_unknown_top_level(raw, warnings)
      check_brand(raw, warnings)
      check_email(raw, warnings)
      check_assets(raw, warnings)
      check_theme(raw, warnings)
      check_features(raw, warnings)
      check_locale(raw, errors, warnings)
      check_roles(raw, errors, warnings)

      { errors: errors, warnings: warnings }
    end

    def check_unknown_top_level(raw, warnings)
      (raw.keys - KNOWN_TOP_LEVEL).each do |key|
        warnings << "Unknown top-level key '#{key}' (ignored). Known keys: #{KNOWN_TOP_LEVEL.join(', ')}."
      end
    end

    def check_brand(raw, warnings)
      brand = raw['brand']
      return if brand.nil?
      return warnings << "'brand' must be a mapping." unless brand.is_a?(Hash)

      warnings << "'brand.name' should be a non-empty string." if blank_string?(brand['name']) && brand.key?('name')
    end

    def check_email(raw, warnings)
      email = raw['email']
      return if email.nil?
      return warnings << "'email' must be a mapping." unless email.is_a?(Hash)

      from = email['from_address']
      warnings << "'email.from_address' (#{from.inspect}) does not look like an email address." \
        if from && !(from.is_a?(String) && from.include?('@'))
    end

    def check_assets(raw, warnings)
      assets = raw['assets']
      return if assets.nil?
      return warnings << "'assets' must be a mapping." unless assets.is_a?(Hash)

      ASSET_KEYS.each do |key|
        val = assets[key]
        next if val.nil?

        unless val.is_a?(String) && val.start_with?('/')
          warnings << "'assets.#{key}' (#{val.inspect}) should be a path starting with '/' (served from public/)."
        end
      end
    end

    def check_theme(raw, warnings)
      theme = raw['theme']
      return if theme.nil?
      return warnings << "'theme' must be a mapping." unless theme.is_a?(Hash)

      HSL_THEME_KEYS.each do |key|
        val = theme[key]
        next if val.nil?

        unless val.is_a?(String) && val.match?(HSL_RE)
          warnings << "'theme.#{key}' (#{val.inspect}) should be an HSL triplet like \"205 68% 32%\"."
        end
      end
    end

    def check_features(raw, warnings)
      features = raw['features']
      return if features.nil?
      return warnings << "'features' must be a mapping." unless features.is_a?(Hash)

      BOOLEAN_FEATURE_KEYS.each do |key|
        val = features[key]
        next if val.nil? || [true, false].include?(val)

        warnings << "'features.#{key}' (#{val.inspect}) should be true or false."
      end
    end

    def check_locale(raw, _errors, warnings)
      locale = raw['locale']
      return if locale.nil?
      return warnings << "'locale' must be a mapping." unless locale.is_a?(Hash)

      avail = locale['available']
      if avail && !(avail.is_a?(Array) && avail.all?(String))
        warnings << "'locale.available' should be a list of strings."
      end

      %w[default fallback].each do |key|
        val = locale[key]
        next if val.nil? || val.is_a?(String)

        warnings << "'locale.#{key}' should be a string locale code."
      end

      if avail.is_a?(Array)
        %w[default fallback].each do |key|
          val = locale[key]
          next if val.nil? || avail.include?(val)

          warnings << "'locale.#{key}' (#{val.inspect}) is not in 'locale.available'."
        end
      end
    end

    def check_roles(raw, errors, warnings)
      roles = raw['roles']
      return if roles.nil?
      return errors << "'roles' must be a mapping of role name => definition." unless roles.is_a?(Hash)
      return errors << "'roles' must define at least one role." if roles.empty?

      roles.each do |name, defn|
        unless defn.is_a?(Hash)
          errors << "Role '#{name}' must be a mapping."
          next
        end

        check_role_permissions(name, defn['permissions'], errors, warnings)
        check_role_sections(name, defn['settings_sections'], warnings)
      end
    end

    def check_role_permissions(name, perms, errors, warnings)
      return errors << "Role '#{name}' is missing a 'permissions' mapping." if perms.nil?
      return errors << "Role '#{name}'.permissions must be a mapping." unless perms.is_a?(Hash)

      (perms.keys - PERMISSION_RESOURCES).each do |res|
        warnings << "Role '#{name}' references unknown resource '#{res}'. Known: #{PERMISSION_RESOURCES.join(', ')}."
      end

      perms.each do |res, actions|
        unless actions.is_a?(Array)
          errors << "Role '#{name}'.permissions.#{res} must be a list of actions."
          next
        end

        (actions - PERMISSION_ACTIONS).each do |act|
          warnings << "Role '#{name}'.permissions.#{res} has unknown action '#{act}'. Known: #{PERMISSION_ACTIONS.join(', ')}."
        end
      end
    end

    def check_role_sections(name, sections, warnings)
      return if sections.nil?

      unless sections.is_a?(Array)
        warnings << "Role '#{name}'.settings_sections should be a list."
        return
      end

      (sections - SETTINGS_SECTIONS).each do |sec|
        warnings << "Role '#{name}'.settings_sections has unknown section '#{sec}'. Known: #{SETTINGS_SECTIONS.join(', ')}."
      end
    end

    def blank_string?(val)
      val.nil? || (val.is_a?(String) && val.strip.empty?)
    end
  end
end
