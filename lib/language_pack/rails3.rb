require "language_pack"
require "language_pack/rails2"

# Rails 3 Language Pack. This is for all Rails 3.x apps.
class LanguagePack::Rails3 < LanguagePack::Rails2
  # detects if this is a Rails 3.x app
  # @return [Boolean] true if it's a Rails 3.x app
  def self.use?
    if gemfile_lock?
      rails_version = LanguagePack::Ruby.gem_version('railties')
      rails_version >= Gem::Version.new('3.0.0') && rails_version < Gem::Version.new('4.0.0') if rails_version
    end
  end

  def name
    "Ruby/Rails"
  end

  def default_process_types
    # let's special case thin here
    web_process = gem_is_bundled?("thin") ?
                    "bundle exec thin start -R config.ru -e $RAILS_ENV -p $PORT" :
                    "bundle exec rails server -p $PORT"

    super.merge({
      "web" => web_process,
      "console" => "bundle exec rails console"
    })
  end

private

  # mjt - Disabled this plugin; not needed as we have a correctly
  # configured environments/production.rb that already does this.
  # def plugins
  #   super.concat(%w( rails3_serve_static_assets )).uniq
  # end

  # runs the tasks for the Rails 3.1 asset pipeline
  def run_assets_precompile_rake_task
    log("assets_precompile") do
      setup_database_url_env

      # retrieve asset version metadata
      cache_load "vendor/alces/assets"
      if assets_need_recompile?
        if rake_task_defined?(ASSET_PRECOMPILE_TASK)
          topic("Preparing app for Rails asset pipeline")
          if File.exists?("public/assets/manifest.yml")
            puts "Detected manifest.yml, assuming assets were compiled locally"
          else
            ENV["RAILS_GROUPS"] ||= "assets"
            ENV["RAILS_ENV"]    ||= "production"
            
            puts "Running: rake #{ASSET_PRECOMPILE_TASK}"
            require 'benchmark'
            time = Benchmark.realtime { pipe("env PATH=$PATH:bin bundle exec rake #{ASSET_PRECOMPILE_TASK} 2>&1") }
            
            if $?.success?
              log "assets_precompile", :status => "success"
              puts "Asset precompilation completed (#{"%.2f" % time}s)"
            else
              log "assets_precompile", :status => "failure"
              puts "Precompiling assets failed, enabling runtime asset compilation"
              install_plugin("rails31_enable_runtime_asset_compilation")
              puts "Please see this article for troubleshooting help:"
              puts "http://devcenter.heroku.com/articles/rails31_heroku_cedar#troubleshooting"
            end
          end
        end
        now_version = File.read('config/assets-version').chomp rescue '1'
        last_version = File.read('vendor/alces/assets/version').chomp rescue '0'
        older_version = File.read('vendor/alces/assets/older_version').chomp rescue (last_version.to_i - 1).to_s

        if now_version != 'FORCE'
          FileUtils.mkdir_p('vendor/alces/assets')
          File.open('vendor/alces/assets/version', 'w') do |file|
            file.puts now_version
          end
          File.open('vendor/alces/assets/older_version', 'w') do |file|
            file.puts last_version
          end
        else
          now_version = last_version
          last_version = older_version
          FileUtils.rm_rf("vendor/alces/assets/#{now_version}")
        end
        # Merge previous set of assets
        # 1. Move new assets into a version-specific directory
        FileUtils.mv('public/dist',"vendor/alces/assets/#{now_version}")
        # 2. Copy last assets into public/dist
        FileUtils.cp_r("vendor/alces/assets/#{last_version}", 'public/dist')
        # 3. Copy now assets into public/dist
        FileUtils.cp_r(Dir.glob("vendor/alces/assets/#{now_version}/*"), 'public/dist') 
        # 4. Remove older assets
        FileUtils.rm_rf("vendor/alces/assets/#{older_version}")
        # store assets
        cache_store "public/dist"
        # store manifest
        cache_store "config/assets"
        # store asset version metadata
        cache_store "vendor/alces/assets"
      else
        # retrieve manifest
        cache_load "config/assets"
        # retrieve assets
        cache_load "public/dist"
      end
      # Clean up build/cache artifacts
      FileUtils.rm_rf('vendor/alces/assets')
    end
  end

  # setup the database url as an environment variable
  def setup_database_url_env
    ENV["DATABASE_URL"] ||= begin
      # need to use a dummy DATABASE_URL here, so rails can load the environment
      scheme =
        if gem_is_bundled?("pg")
          "postgres"
        elsif gem_is_bundled?("mysql")
          "mysql"
        elsif gem_is_bundled?("mysql2")
          "mysql2"
        elsif gem_is_bundled?("sqlite3") || gem_is_bundled?("sqlite3-ruby")
          "sqlite3"
        end
      "#{scheme}://user:pass@127.0.0.1/dbname"
    end
  end

  def assets_need_recompile?
    if !cache_exists?("public/dist") || !cache_exists?("vendor/alces/assets")
      return true
    else
      # check that no assets have changed since they were last compiled
      now_version = File.read('config/assets-version').chomp rescue '1'
      last_version = File.read('vendor/alces/assets/version').chomp rescue '0'
      now_version == 'FORCE' || now_version != last_version
    end
  end
end
