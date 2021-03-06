require "plist"

module Fastlane
  module Helper
    module IOSHelper
      APPLINKS = "applinks"
      ASSOCIATED_DOMAINS = "com.apple.developer.associated-domains"
      CODE_SIGN_ENTITLEMENTS = "CODE_SIGN_ENTITLEMENTS"
      DEVELOPMENT_TEAM = "DEVELOPMENT_TEAM"
      PRODUCT_BUNDLE_IDENTIFIER = "PRODUCT_BUNDLE_IDENTIFIER"
      RELEASE_CONFIGURATION = "Release"

      def add_keys_to_info_plist(project, target_name, keys, configuration = RELEASE_CONFIGURATION)
        update_info_plist_setting project, target_name, configuration do |info_plist|
          # add/overwrite Branch key(s)
          if keys.count > 1
            info_plist["branch_key"] = keys
          elsif keys[:live]
            info_plist["branch_key"] = keys[:live]
          else # no need to validate here, which was done by the action
            info_plist["branch_key"] = keys[:test]
          end
        end
      end

      def add_branch_universal_link_domains_to_info_plist(project, target_name, domains, configuration = RELEASE_CONFIGURATION)
        # Add all supplied domains unless all are app.link domains.
        return if domains.all? { |d| d =~ /app\.link$/ }

        update_info_plist_setting project, target_name, configuration do |info_plist|
          info_plist["branch_universal_link_domains"] = domains
        end
      end

      def update_info_plist_setting(project, target_name, configuration = RELEASE_CONFIGURATION, &b)
        # raises
        target = target_from_project project, target_name

        # find the Info.plist paths for this configuration
        info_plist_path = expanded_build_setting target, "INFOPLIST_FILE", configuration

        raise "Info.plist not found for configuration #{configuration}" if info_plist_path.nil?

        project_parent = File.dirname project.path

        info_plist_path = File.expand_path info_plist_path, project_parent

        # try to open and parse the Info.plist (raises)
        info_plist = File.open(info_plist_path) { |f| Plist.parse_xml f }
        raise "Failed to parse #{info_plist_path}" if info_plist.nil?

        yield info_plist

        Plist::Emit.save_plist info_plist, info_plist_path
        add_change info_plist_path
      end

      def add_universal_links_to_project(project, target_name, domains, remove_existing, configuration = RELEASE_CONFIGURATION)
        # raises
        target = target_from_project project, target_name

        relative_entitlements_path = expanded_build_setting target, CODE_SIGN_ENTITLEMENTS, configuration
        project_parent = File.dirname project.path

        if relative_entitlements_path.nil?
          relative_entitlements_path = File.join target.name, "#{target.name}.entitlements"
          entitlements_path = File.expand_path relative_entitlements_path, project_parent

          # Add CODE_SIGN_ENTITLEMENTS setting to each configuration
          target.build_configuration_list.set_setting CODE_SIGN_ENTITLEMENTS, relative_entitlements_path

          # Add the file to the project
          project.new_file relative_entitlements_path

          entitlements = {}
          current_domains = []

          add_change project.path
          new_path = entitlements_path
        else
          entitlements_path = File.expand_path relative_entitlements_path, project_parent
          # Raises
          entitlements = File.open(entitlements_path) { |f| Plist.parse_xml f }
          raise "Failed to parse entitlements file #{entitlements_path}" if entitlements.nil?

          if remove_existing
            current_domains = []
          else
            current_domains = entitlements[ASSOCIATED_DOMAINS]
          end
        end

        current_domains += domains.map { |d| "#{APPLINKS}:#{d}" }
        all_domains = current_domains.uniq

        entitlements[ASSOCIATED_DOMAINS] = all_domains

        Plist::Emit.save_plist entitlements, entitlements_path
        add_change entitlements_path

        new_path
      end

      def team_and_bundle_from_app_id(identifier)
        team = identifier.sub(/\..+$/, "")
        bundle = identifier.sub(/^[^.]+\./, "")
        [team, bundle]
      end

      def update_team_and_bundle_ids_from_aasa_file(project, target_name, domain)
        # raises
        identifiers = app_ids_from_aasa_file domain
        raise "Multiple appIDs found in AASA file" if identifiers.count > 1

        identifier = identifiers[0]
        team, bundle = team_and_bundle_from_app_id identifier

        update_team_and_bundle_ids project, target_name, team, bundle
        add_change project.path.expand_path
      end

      def validate_team_and_bundle_ids_from_aasa_files(project, target_name, domains = [], remove_existing = false, configuration = RELEASE_CONFIGURATION)
        @errors = []
        valid = true

        # Include any domains already in the project.
        # Raises. Returns a non-nil array of strings.
        if remove_existing
          # Don't validate domains to be removed (#16)
          all_domains = domains
        else
          all_domains = (domains + domains_from_project(project, target_name, configuration)).uniq
        end

        if all_domains.empty?
          # Cannot get here from SetupBranchAction, since the domains passed in will never be empty.
          # If called from ValidateUniversalLinksAction, this is a failure, possibly caused by
          # failure to add applinks:.
          @errors << "No Universal Link domains in project. Be sure each Universal Link domain is prefixed with applinks:."
          return false
        end

        all_domains.each do |domain|
          domain_valid = validate_team_and_bundle_ids project, target_name, domain, configuration
          valid &&= domain_valid
          UI.message "Valid Universal Link configuration for #{domain} ✅" if domain_valid
        end
        valid
      end

      def app_ids_from_aasa_file(domain)
        data = contents_of_aasa_file domain
        # errors reported in the method above
        return nil if data.nil?

        # raises
        file = JSON.parse data

        applinks = file[APPLINKS]
        @errors << "[#{domain}] No #{APPLINKS} found in AASA file" and return if applinks.nil?

        details = applinks["details"]
        @errors << "[#{domain}] No details found for #{APPLINKS} in AASA file" and return if details.nil?

        identifiers = details.map { |d| d["appID"] }.uniq
        @errors << "[#{domain}] No appID found in AASA file" and return if identifiers.count <= 0
        identifiers
      rescue JSON::ParserError => e
        @errors << "[#{domain}] Failed to parse AASA file: #{e.message}"
        nil
      end

      def contents_of_aasa_file(domain)
        uris = [
          URI("https://#{domain}/.well-known/apple-app-site-association"),
          URI("https://#{domain}/apple-app-site-association")
        ]

        data = nil

        uris.each do |uri|
          break unless data.nil?

          Net::HTTP.start uri.host, uri.port, use_ssl: uri.scheme == "https" do |http|
            request = Net::HTTP::Get.new uri
            response = http.request request

            # Better to use Net::HTTPRedirection and Net::HTTPSuccess here, but
            # having difficulty with the unit tests.
            if (300..399).cover?(response.code.to_i)
              UI.important "#{uri} cannot result in a redirect. Ignoring."
              next
            elsif response.code.to_i != 200
              # Try the next URI.
              UI.message "Could not retrieve #{uri}: #{response.code} #{response.message}. Ignoring."
              next
            end

            content_type = response["Content-type"]
            @errors << "[#{domain}] AASA Response does not contain a Content-type header" and return nil if content_type.nil?

            case content_type
            when %r{application/pkcs7-mime}
              # Verify/decrypt PKCS7 (non-Branch domains)
              cert_store = OpenSSL::X509::Store.new
              signature = OpenSSL::PKCS7.new response.body
              # raises
              signature.verify [http.peer_cert], cert_store, nil, OpenSSL::PKCS7::NOVERIFY
              data = signature.data
            else
              data = response.body
            end

            UI.message "GET #{uri}: #{response.code} #{response.message} (Content-type:#{content_type}) ✅"
          end
        end

        @errors << "[#{domain}] Failed to retrieve AASA file" and return nil if data.nil?

        data
      rescue IOError, SocketError => e
        @errors << "[#{domain}] Socket error: #{e.message}"
        nil
      rescue OpenSSL::PKCS7::PKCS7Error => e
        @errors << "[#{domain}] Failed to verify signed AASA file: #{e.message}"
        nil
      end

      def validate_team_and_bundle_ids(project, target_name, domain, configuration)
        # raises
        target = target_from_project project, target_name

        product_bundle_identifier = expanded_build_setting target, PRODUCT_BUNDLE_IDENTIFIER, configuration
        development_team = expanded_build_setting target, DEVELOPMENT_TEAM, configuration

        identifiers = app_ids_from_aasa_file domain
        return false if identifiers.nil?

        app_id = "#{development_team}.#{product_bundle_identifier}"
        match_found = identifiers.include? app_id

        unless match_found
          @errors << "[#{domain}] appID mismatch. Project: #{app_id}. AASA: #{identifiers}"
        end

        match_found
      end

      def validate_project_domains(expected, project, target, configuration = RELEASE_CONFIGURATION)
        @errors = []
        project_domains = domains_from_project project, target, configuration
        valid = expected.count == project_domains.count
        if valid
          sorted = expected.sort
          project_domains.sort.each_with_index do |domain, index|
            valid = false and break unless sorted[index] == domain
          end
        end

        unless valid
          @errors << "Project domains do not match :domains parameter"
          @errors << "Project domains: #{project_domains}"
          @errors << ":domains parameter: #{expected}"
        end

        valid
      end

      def update_team_and_bundle_ids(project, target_name, team, bundle)
        # raises
        target = target_from_project project, target_name

        target.build_configuration_list.set_setting PRODUCT_BUNDLE_IDENTIFIER, bundle
        target.build_configuration_list.set_setting DEVELOPMENT_TEAM, team

        # also update the team in the first test target
        target = project.targets.find(&:test_target_type?)
        return if target.nil?

        target.build_configuration_list.set_setting DEVELOPMENT_TEAM, team
      end

      def target_from_project(project, target_name)
        if target_name
          target = project.targets.find { |t| t.name == target_name }
          raise "Target #{target} not found" if target.nil?
        else
          # find the first application target
          target = project.targets.find { |t| !t.extension_target_type? && !t.test_target_type? }
          raise "No application target found" if target.nil?
        end
        target
      end

      def domains_from_project(project, target_name, configuration = RELEASE_CONFIGURATION)
        # Raises. Does not return nil.
        target = target_from_project project, target_name

        relative_entitlements_path = expanded_build_setting target, CODE_SIGN_ENTITLEMENTS, configuration
        return [] if relative_entitlements_path.nil?

        project_parent = File.dirname project.path
        entitlements_path = File.expand_path relative_entitlements_path, project_parent

        # Raises
        entitlements = File.open(entitlements_path) { |f| Plist.parse_xml f }
        raise "Failed to parse entitlements file #{entitlements_path}" if entitlements.nil?

        entitlements[ASSOCIATED_DOMAINS].select { |d| d =~ /^applinks:/ }.map { |d| d.sub(/^applinks:/, "") }
      end

      def expanded_build_setting(target, setting_name, configuration)
        setting_value = target.resolved_build_setting(setting_name)[configuration]
        return if setting_value.nil?

        search_position = 0
        while (matches = /\$\(([^(){}]*)\)|\$\{([^(){}]*)\}/.match(setting_value, search_position))
          macro_name = matches[1] || matches[2]
          search_position = setting_value.index(macro_name) - 2

          expanded_macro = macro_name == "SRCROOT" ? "." : expanded_build_setting(target, macro_name, configuration)
          search_position += macro_name.length + 3 and next if expanded_macro.nil?

          setting_value.gsub!(/\$\(#{macro_name}\)|\$\{#{macro_name}\}/, expanded_macro)
          search_position += expanded_macro.length
        end
        setting_value
      end
    end
  end
end
