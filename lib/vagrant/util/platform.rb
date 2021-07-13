require "rbconfig"
require "shellwords"
require "tempfile"
require "tmpdir"
require "log4r"

require "vagrant/util/subprocess"
require "vagrant/util/powershell"
require "vagrant/util/which"

module Vagrant
  module Util
    # This class just contains some platform checking code.
    class Platform
      class << self

        def logger
          if !defined?(@_logger)
            @_logger = Log4r::Logger.new("vagrant::util::platform")
          end
          @_logger
        end

        def cygwin?
          if !defined?(@_cygwin)
            @_cygwin = ENV["VAGRANT_DETECTED_OS"].to_s.downcase.include?("cygwin") ||
              platform.include?("cygwin") ||
              ENV["OSTYPE"].to_s.downcase.include?("cygwin")
          end
          @_cygwin
        end

        def msys?
          if !defined?(@_msys)
            @_msys = ENV["VAGRANT_DETECTED_OS"].to_s.downcase.include?("msys") ||
              platform.include?("msys") ||
              ENV["OSTYPE"].to_s.downcase.include?("msys")
          end
          @_msys
        end

        def wsl?
          if !defined?(@_wsl)
            @_wsl = false
            SilenceWarnings.silence! do
              # Find 'microsoft' in /proc/version indicative of WSL
              if File.file?('/proc/version')
                osversion = File.open('/proc/version', &:gets)
                if osversion.downcase.include?("microsoft")
                  @_wsl = true
                end
              end
            end
          end
          @_wsl
        end

        [:darwin, :bsd, :freebsd, :linux, :solaris].each do |type|
          define_method("#{type}?") do
            platform.include?(type.to_s)
          end
        end

        def windows?
          return @_windows if defined?(@_windows)
          @_windows = %w[mingw mswin].any? { |t| platform.include?(t) }
          return @_windows
        end

        # Checks if the user running Vagrant on Windows has administrative
        # privileges.
        #
        # From: https://support.microsoft.com/en-us/kb/243330
        # SID: S-1-5-19
        #
        # @return [Boolean]
        def windows_admin?
          return @_windows_admin if defined?(@_windows_admin)

          @_windows_admin = -> {
            ps_cmd = '(new-object System.Security.Principal.WindowsPrincipal([System.Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)'
            output = Vagrant::Util::PowerShell.execute_cmd(ps_cmd)
            return output == 'True'
          }.call

          return @_windows_admin
        end

        # Checks if Hyper-V is accessible to the local user. It will check
        # if user is in the "Hyper-V Administrators" group, is a Domain
        # administrator, and finally will run a manual interaction with
        # Hyper-V to determine if Hyper-V is usable for the current user.
        #
        # From: https://support.microsoft.com/en-us/kb/243330
        # SID: S-1-5-32-578
        # Name: BUILTIN\Hyper-V Administrators
        # SID: S-1-5-21DOMAIN-512
        # Name: Domain Admins
        #
        # @return [Boolean]
        def windows_hyperv_admin?
          return @_windows_hyperv_admin if defined?(@_windows_hyperv_admin)

          if ENV["VAGRANT_IS_HYPERV_ADMIN"]
            return @_windows_hyperv_admin = true
          end

          ps_cmd = "Write-Output ([System.Security.Principal.WindowsIdentity]::GetCurrent().Groups | " \
            "Select-Object Value | ConvertTo-JSON)"
          output = Vagrant::Util::PowerShell.execute_cmd(ps_cmd)
          if output
            groups = begin
                       JSON.load(output)
                     rescue JSON::ParserError
                       []
                     end
            admin_group = groups.detect do |g|
              g["Value"].to_s == "S-1-5-32-578" ||
                (g["Value"].start_with?("S-1-5-21") && g["Value"].to_s.end_with?("-512"))
            end

            if admin_group
              return @_windows_hyperv_admin = true
            end
          end

          ps_cmd = "$x = (Get-VMHost).Name; if($x -eq [System.Net.Dns]::GetHostName()){ Write-Output 'true'}"
          output = Vagrant::Util::PowerShell.execute_cmd(ps_cmd)
          result = output == "true"

          return @_windows_hyperv_admin = result
        end

        # Checks if Hyper-V is enabled on the host system and returns true
        # if enabled.
        #
        # @return [Boolean]
        def windows_hyperv_enabled?
          return @_windows_hyperv_enabled if defined?(@_windows_hyperv_enabled)

          @_windows_hyperv_enabled = -> {
            check_commands = Array.new.tap do |c|
              c << "(Get-WindowsOptionalFeature -FeatureName Microsoft-Hyper-V-Hypervisor -Online).State"
              c << "(Get-WindowsFeature -FeatureName Microsoft-Hyper-V-Hypervisor).State"
            end
            check_commands.each do |ps_cmd|
              begin
                output = Vagrant::Util::PowerShell.execute_cmd(ps_cmd)
                return true if output == "Enabled"
              rescue Errors::PowerShellInvalidVersion
                logger.warn("Invalid PowerShell version detected during Hyper-V enable check")
                return false
              rescue Errors::PowerShellError
                logger.warn("Powershell command not found or error on execution of command")
                return false
              end
            end
            return false
          }.call

          return @_windows_hyperv_enabled
        end

        # This takes any path and converts it from a Windows path to a
        # Cygwin style path.
        #
        # @param [String] path
        # @return [String]
        def cygwin_path(path)
          begin
            cygpath = Vagrant::Util::Which.which("cygpath")
            if cygpath.nil?
              # If Which can't find it, just attempt to invoke it directly
              cygpath = "cygpath"
            else
              cygpath.gsub!("/", '\\')
            end

            process = Subprocess.execute(
              cygpath, "-u", "-a", path.to_s)
            return process.stdout.chomp
          rescue Errors::CommandUnavailableWindows => e
            # Sometimes cygpath isn't available (msys). Instead, do what we
            # can with bash tricks.
            process = Subprocess.execute(
              "bash",
              "--noprofile",
              "--norc",
              "-c", "cd #{Shellwords.escape(path)} && pwd")
            return process.stdout.chomp
          end
        end

        # This takes any path and converts it from a Windows path to a
        # msys style path.
        #
        # @param [String] path
        # @return [String]
        def msys_path(path)
          begin
            # We have to revert to the old env
            # path here, otherwise it looks like
            # msys2 ends up using the wrong cygpath
            # binary and ends up with a `/cygdrive`
            # when it doesn't exist in msys2
            original_path_env = ENV['PATH']
            ENV['PATH'] = ENV['VAGRANT_OLD_ENV_PATH']
            cygwin_path(path)
          ensure
            ENV['PATH'] = original_path_env
          end
        end

        # This takes any path and converts it to a full-length Windows
        # path on Windows machines in Cygwin.
        #
        # @return [String]
        def cygwin_windows_path(path)
          return path if !cygwin?

          # Replace all "\" with "/", otherwise cygpath doesn't work.
          path = unix_windows_path(path)

          # Call out to cygpath and gather the result
          process = Subprocess.execute("cygpath", "-w", "-l", "-a", path.to_s)
          return process.stdout.chomp
        end

        # This takes any path and converts Windows-style path separators
        # to Unix-like path separators.
        # @return [String]
        def unix_windows_path(path)
          path.gsub("\\", "/")
        end

        # This checks if the filesystem is case sensitive. This is not a
        # 100% correct check, since it is possible that the temporary
        # directory runs a different filesystem than the root directory.
        # However, this works in many cases.
        def fs_case_sensitive?
          return @_fs_case_sensitive if defined?(@_fs_case_sensitive)
          @_fs_case_sensitive = Dir.mktmpdir("vagrant-fs-case-sensitive") do |dir|
            tmp_file = File.join(dir, "FILE")
            File.open(tmp_file, "w") do |f|
              f.write("foo")
            end

            # The filesystem is case sensitive if the lowercased version
            # of the filename is NOT reported as existing.
            !File.file?(File.join(dir, "file"))
          end
          return @_fs_case_sensitive
        end

        # This expands the path and ensures proper casing of each part
        # of the path.
        def fs_real_path(path, **opts)
          path = Pathname.new(File.expand_path(path))

          if path.exist? && !fs_case_sensitive?
            # If the path contains a Windows short path, then we attempt to
            # expand. The require below is embedded here since it requires
            # windows to work.
            if windows? && path.to_s =~ /~\d(\/|\\)/
              require_relative "windows_path"
              path = Pathname.new(WindowsPath.longname(path.to_s))
            end

            # Build up all the parts of the path
            original = []
            while !path.root?
              original.unshift(path.basename.to_s)
              path = path.parent
            end

            # Traverse each part and join it into the resulting path
            original.each do |single|
              Dir.entries(path).each do |entry|
                begin
                  single = single.encode("filesystem").to_s
                rescue ArgumentError => err
                  Vagrant.global_logger.warn("path encoding failed - part=#{single} err=#{err.class} msg=#{err}")
                  # NOTE: Depending on the Windows environment the above
                  # encode will generate an "input string invalid" when
                  # attempting to encode. If that happens, continue on
                end
                if entry.downcase == single.downcase
                  path = path.join(entry)
                end
              end
            end
          end

          if windows?
            # Fix the drive letter to be uppercase.
            path = path.to_s
            if path[1] == ":"
              path[0] = path[0].upcase
            end

            path = Pathname.new(path)
          end

          path
        end

        # Converts a given path to UNC format by adding a prefix and converting slashes.
        # @param [String] path Path to convert to UNC for Windows
        # @return [String]
        def windows_unc_path(path)
          path = path.gsub("/", "\\")

          # Convert to UNC path
          if path =~ /^[a-zA-Z]:\\?$/
            # If the path is just a drive letter, then return that as-is
            path + "\\"
          elsif path.start_with?("\\\\")
            # If the path already starts with `\\` assume UNC and return as-is
            path
          else
            "\\\\?\\" + path.gsub("/", "\\")
          end
        end

        # Returns a boolean noting whether the terminal supports color.
        # output.
        def terminal_supports_colors?
          return @_terminal_supports_colors if defined?(@_terminal_supports_colors)
          @_terminal_supports_colors = -> {
            if windows?
              return true if ENV.key?("ANSICON")
              return true if cygwin?
              return true if ENV["TERM"] == "cygwin"
              return false
            end

            return true
          }.call
          return @_terminal_supports_colors
        end

        def platform
          return @_platform if defined?(@_platform)
          @_platform = RbConfig::CONFIG["host_os"].downcase
          return @_platform
        end

        # Determine if given path is within the WSL rootfs. Returns
        # true if within the subsystem, or false if outside the subsystem.
        #
        # @param [String] path Path to check
        # @return [Boolean] path is within subsystem
        def wsl_path?(path)
          wsl? && !path.to_s.downcase.start_with?("/mnt/")
        end

        # Compute the path to rootfs of currently active WSL.
        #
        # @return [String] A path to rootfs of a current WSL instance.
        def wsl_rootfs
          return @_wsl_rootfs if defined?(@_wsl_rootfs)

          if wsl?
            # Mark our filesystem with a temporary file having an unique name.
            marker = Tempfile.new(Time.now.to_i.to_s)
            logger = Log4r::Logger.new("vagrant::util::platform::wsl")

            # Check for lxrun installation first
            lxrun_path = [wsl_windows_appdata_local, "lxss"].join("\\")
            paths = [lxrun_path]

            logger.debug("checking registry for WSL installation path")
            paths += PowerShell.execute_cmd(
              '(Get-ChildItem HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss ' \
                '| ForEach-Object {Get-ItemProperty $_.PSPath}).BasePath').to_s.split("\r\n").map(&:strip)
            paths.delete_if{|path| path.to_s.empty?}

            paths.each do |path|
              # Lowercase the drive letter, skip the next symbol (which is a
              # colon from a Windows path) and convert path to UNIX style.
              check_path = "/mnt/#{path[0, 1].downcase}#{path[2..-1].tr('\\', '/')}/rootfs"
              begin
                process = Subprocess.execute("wslpath", "-u", "-a", path)
                check_path = "#{process.stdout.chomp}/rootfs" if process.exit_code == 0
              rescue Errors::CommandUnavailable => e
                # pass
              end

              logger.debug("checking `#{path}` for current WSL instance")
              begin
                # https://blogs.msdn.microsoft.com/wsl/2016/06/15/wsl-file-system-support
                # Current WSL instance doesn't have an access to its mount from
                # within itself despite all others are available. That's the
                # hacky way we're using to determine current instance.
                # For example we have three WSL instances:
                # A -> C:\User\USER\AppData\Local\Packages\A\LocalState\rootfs
                # B -> C:\User\USER\AppData\Local\Packages\B\LocalState\rootfs
                # C -> C:\User\USER\AppData\Local\Packages\C\LocalState\rootfs
                # If we're in "A" WSL at the moment, then its path will not be
                # accessible since it's mounted for exactly the instance we're
                # in. All others can be opened.
                Dir.open(check_path) do |fs|
                  # A fallback for a case if our trick will stop working. For
                  # that we've created a temporary file with an unique name in
                  # a current WSL and now seeking it among all WSL.
                  if File.exist?("#{fs.path}/#{marker.path}")
                    @_wsl_rootfs = path
                    break
                  end
                end
              rescue Errno::EACCES
                @_wsl_rootfs = path
                # You can create and simultaneously run multiple WSL instances,
                # comment out the "break", run this script within each one and
                # it'll return only single value.
                break
              rescue Errno::ENOENT
                # Warn about data discrepancy between Winreg and file system
                # states. For the sake of justice, it's worth mentioning that
                # it is possible only when someone will manually break WSL by
                # removing a directory of its base path (kinda "stupid WSL
                # uninstallation by removing hidden and system directory").
                logger.warn("WSL instance at `#{path} is broken or no longer exists")
              end
              # All other exceptions have to be raised since they will mean
              # something unpredictably terrible.
            end

            marker.close!

            raise Vagrant::Errors::WSLRootFsNotFoundError if @_wsl_rootfs.nil?
          end

          # Attach the rootfs leaf to the path
          if @_wsl_rootfs != lxrun_path
            @_wsl_rootfs = "#{@_wsl_rootfs}\\rootfs"
          end

          logger.debug("detected `#{@_wsl_rootfs}` as current WSL instance")

          @_wsl_rootfs
        end

        # Convert a WSL path to the local Windows path. This is useful
        # for conversion when calling out to Windows executables from
        # the WSL
        #
        # @param [String, Pathname] path Path to convert
        # @return [String]
        def wsl_to_windows_path(path)
          path = path.to_s
          if wsl? && wsl_windows_access? && !path.match(/^[a-zA-Z]:/)
            path = File.expand_path(path)
            begin
              process = Subprocess.execute("wslpath", "-w", "-a", path)
              return process.stdout.chomp if process.exit_code == 0
            rescue Errors::CommandUnavailable => e
              # pass
            end
            if wsl_path?(path)
              parts = path.split("/")
              parts.delete_if(&:empty?)
              root_path = wsl_rootfs
              # lxrun splits home separate so we need to account
              # for it's specialness here when we build the path
              if root_path.end_with?("lxss") && !(["root", "home"].include?(parts.first))
                root_path = "#{root_path}\\rootfs"
              end
              path = [root_path, *parts].join("\\")
            else
              path = path.sub("/mnt/", "")
              parts = path.split("/")
              parts.first << ":"
              path = parts.join("\\")
            end
          end
          path
        end

        # Takes a windows path and formats it to the
        # 'unix' style (i.e. `/cygdrive/c` or `/c/`)
        #
        # @param [Pathname, String] path Path to convert
        # @param [Hash] hash of arguments
        # @return [String]
        def format_windows_path(path, *args)
          path = cygwin_path(path) if cygwin?
          path = msys_path(path) if msys?
          path = wsl_to_windows_path(path) if wsl?
          if windows? || wsl?
            path = windows_unc_path(path) if !args.include?(:disable_unc)
          end

          path
        end

        # Automatically convert a given path to a Windows path. Will only
        # be applied if running on a Windows host. If running on Windows
        # host within the WSL, the actual Windows path will be returned.
        #
        # @param [Pathname, String] path Path to convert
        # @return [String]
        def windows_path(path)
          path = cygwin_windows_path(path)
          path = wsl_to_windows_path(path)
          if windows? || wsl?
            path = windows_unc_path(path)
          end
          path
        end

        # Allow Vagrant to access Vagrant managed machines outside the
        # Windows Subsystem for Linux
        #
        # @return [Boolean]
        def wsl_windows_access?
          if !defined?(@_wsl_windows_access)
            @_wsl_windows_access = wsl? && ENV["VAGRANT_WSL_ENABLE_WINDOWS_ACCESS"]
          end
          @_wsl_windows_access
        end

        # The allowed windows system path Vagrant can manage from the Windows
        # Subsystem for Linux
        #
        # @return [Pathname]
        def wsl_windows_accessible_path
          if !defined?(@_wsl_windows_accessible_path)
            access_path = ENV["VAGRANT_WSL_WINDOWS_ACCESS_USER_HOME_PATH"]
            if access_path.to_s.empty?
              begin
                process = Subprocess.execute("wslpath", "-u", "-a", wsl_windows_home)
                access_path = process.stdout.chomp if process.exit_code == 0
              rescue Errors::CommandUnavailable => e
                # pass
              end
            end
            if access_path.to_s.empty?
              access_path = wsl_windows_home.gsub("\\", "/").sub(":", "")
              access_path[0] = access_path[0].downcase
              access_path = "/mnt/#{access_path}"
            end
            @_wsl_windows_accessible_path = Pathname.new(access_path)
          end
          @_wsl_windows_accessible_path
        end

        # Checks given path to determine if Vagrant is allowed to bypass checks
        #
        # @param [String] path Path to check
        # @return [Boolean] Vagrant is allowed to bypass checks
        def wsl_windows_access_bypass?(path)
          wsl? && wsl_windows_access? &&
            path.to_s.start_with?(wsl_windows_accessible_path.to_s)
        end

        # Mount pattern for extracting local mount information
        MOUNT_PATTERN = /^(?<device>.+?) on (?<mount>.+?) type (?<type>.+?) \((?<options>.+)\)/.freeze

        # Get list of local mount paths that are DrvFs file systems
        #
        # @return [Array<String>]
        # @todo(chrisroberts): Constantize types for check
        def wsl_drvfs_mounts
          if !defined?(@_wsl_drvfs_mounts)
            @_wsl_drvfs_mounts = []
            if wsl?
              result = Util::Subprocess.execute("mount")
              result.stdout.each_line do |line|
                info = line.match(MOUNT_PATTERN)
                if info && (info[:type] == "drvfs" || info[:type] == "9p")
                  @_wsl_drvfs_mounts << info[:mount]
                end
              end
            end
          end
          @_wsl_drvfs_mounts
        end

        # Check if given path is located on DrvFs file system
        #
        # @param [String, Pathname] path Path to check
        # @return [Boolean]
        def wsl_drvfs_path?(path)
          if wsl?
            wsl_drvfs_mounts.each do |mount_path|
              return true if path.to_s.start_with?(mount_path)
            end
          end
          false
        end

        # If running within the Windows Subsystem for Linux, this will provide
        # simple setup to allow sharing of the user's VAGRANT_HOME directory
        # within the subsystem
        #
        # @param [Environment] env
        # @param [Logger] logger Optional logger to display information
        def wsl_init(env, logger=nil)
          if wsl?
            if ENV["VAGRANT_WSL_ENABLE_WINDOWS_ACCESS"]
              wsl_validate_matching_vagrant_versions!
              shared_user = ENV["VAGRANT_WSL_WINDOWS_ACCESS_USER"]
              if shared_user.to_s.empty?
                shared_user = wsl_windows_username
              end
              if logger
                logger.warn("Windows Subsystem for Linux detected. Allowing access to user: #{shared_user}")
                logger.warn("Vagrant will be allowed to control Vagrant managed machines within the user's home path.")
              end
              if ENV["VAGRANT_HOME"] || ENV["VAGRANT_WSL_DISABLE_VAGRANT_HOME"]
                logger.warn("VAGRANT_HOME environment variable already set. Not overriding!") if logger
              else
                home_path = wsl_windows_accessible_path.to_s
                ENV["VAGRANT_HOME"] = File.join(home_path, ".vagrant.d")
                if logger
                  logger.info("Overriding VAGRANT_HOME environment variable to configured windows user. (#{ENV["VAGRANT_HOME"]})")
                end
                true
              end
            else
              if env.local_data_path.to_s.start_with?("/mnt/")
                raise Vagrant::Errors::WSLVagrantAccessError
              end
            end
          end
        end

        # Fetch the Windows username currently in use
        #
        # @return [String, Nil]
        def wsl_windows_username
          if !@_wsl_windows_username
            result = Util::Subprocess.execute("cmd.exe", "/c", "echo %USERNAME%")
            if result.exit_code == 0
              @_wsl_windows_username = result.stdout.strip
            end
          end
          @_wsl_windows_username
        end

        # Fetch the Windows user home directory
        #
        # @return [String, Nil]
        def wsl_windows_home
          if !@_wsl_windows_home
            result = Util::Subprocess.execute("cmd.exe", "/c" "echo %USERPROFILE%")
            if result.exit_code == 0
              @_wsl_windows_home = result.stdout.gsub("\"", "").strip
            end
          end
          @_wsl_windows_home
        end

        # Fetch the Windows user local app data directory
        #
        # @return [String, Nil]
        def wsl_windows_appdata_local
          if !@_wsl_windows_appdata_local
            result = Util::Subprocess.execute("cmd.exe", "/c", "echo %LOCALAPPDATA%")
            if result.exit_code == 0
              @_wsl_windows_appdata_local = result.stdout.gsub("\"", "").strip
            end
          end
          @_wsl_windows_appdata_local
        end

        # Confirm Vagrant versions installed within the WSL and the Windows system
        # are the same. Raise error if they do not match.
        def wsl_validate_matching_vagrant_versions!
          valid = false
          if Util::Which.which("vagrant.exe")
            result = Util::Subprocess.execute("vagrant.exe", "--version")
            if result.exit_code == 0
              windows_version = result.stdout.match(/Vagrant (?<version>[\w.-]+)/)
              if windows_version
                windows_version = windows_version[:version].strip
                valid = windows_version == Vagrant::VERSION
              end
            end
            if !valid
              raise Vagrant::Errors::WSLVagrantVersionMismatch,
                wsl_version: Vagrant::VERSION,
                windows_version: windows_version || "unknown"
            end
          end
        end

        # systemd is in use
        def systemd?
          if !defined?(@_systemd)
            if !windows?
              result = Vagrant::Util::Subprocess.execute("ps", "-o", "comm=", "1")
              @_systemd = result.stdout.chomp == "systemd"
            else
              @_systemd = false
            end
          end
          @_systemd
        end

        # @private
        # Reset the cached values for platform. This is not considered a public
        # API and should only be used for testing.
        def reset!
          instance_variables.each(&method(:remove_instance_variable))
        end
      end
    end
  end
end
