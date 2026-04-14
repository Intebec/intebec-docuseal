# frozen_string_literal: true

# =============================================================================
# Heartbeat — pings an external uptime URL (e.g. healthchecks.io) so Intebec
# is alerted automatically when an instance stops responding.
# =============================================================================
#
# Config (in config.yml):
#   observability:
#     heartbeat_url: "https://hc-ping.com/<uuid>"
#     heartbeat_interval_seconds: 300   # optional, default 5 min
#
# If no URL is set, this is a no-op. Only runs inside the web/worker process
# (not during asset precompile, rake tasks, or the setup wizard).
# =============================================================================

return unless defined?(Rails::Server) || ENV['SIDEKIQ_CLI'] == '1'
return if Rails.env.test?

heartbeat_url = Whitelabel.heartbeat_url
return if heartbeat_url.blank?

interval = Whitelabel.heartbeat_interval_seconds

Rails.application.config.after_initialize do
  Thread.new do
    Thread.current.name = 'whitelabel-heartbeat'
    Thread.current.abort_on_exception = false

    loop do
      begin
        uri = URI.parse(heartbeat_url)
        Net::HTTP.start(uri.host, uri.port,
                        use_ssl: uri.scheme == 'https',
                        open_timeout: 5,
                        read_timeout: 5) do |http|
          http.request(Net::HTTP::Get.new(uri.request_uri))
        end
      rescue StandardError => e
        Rails.logger.warn "[Heartbeat] Ping failed: #{e.message}"
      end

      sleep interval
    end
  end
  Rails.logger.info "[Heartbeat] Pinging #{heartbeat_url} every #{interval}s"
end
