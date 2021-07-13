require "json"
require "log4r"

require_relative "./driver/compose"

module VagrantPlugins
  module DockerProvider
    class Driver
      # The executor is responsible for actually executing Docker commands.
      # This is set by the provider, but defaults to local execution.
      attr_accessor :executor

      def initialize
        @logger   = Log4r::Logger.new("vagrant::docker::driver")
        @executor = Executor::Local.new
      end

      # Returns the id for a new container built from `docker build`. Raises
      # an exception if the id was unable to be captured from the output
      #
      # @return [String] id - ID matched from the docker build output.
      def build(dir, **opts, &block)
        args = Array(opts[:extra_args])
        args << dir
        opts = {with_stderr: true}
        result = execute('docker', 'build', *args, **opts, &block)
        # Check for the new output format 'writing image sha256...'
        # In this case, docker buildkit is enabled. Its format is different
        # from standard docker
        matches = result.scan(/writing image .+:([^\s]+)/i).last
        if !matches
          if podman?
            # Check for podman format when it is emulating docker CLI.
            # Podman outputs the full hash of the container on
            # the last line after a successful build.
            match = result.split.select { |str| str.match?(/[0-9a-z]{64}/) }.last
            return match[0..7] unless match.nil?
          else
            matches = result.scan(/Successfully built (.+)$/i).last
          end

          if !matches
            # This will cause a stack trace in Vagrant, but it is a bug
            # if this happens anyways.
            raise Errors::BuildError, result: result
          end
        end

        # Return the matched group `id`
        matches[0].strip
      end

      # Check if podman emulating docker CLI is enabled.
      #
      # @return [Bool]
      def podman?
        execute('docker', '--version').include?("podman")
      end

      def create(params, **opts, &block)
        image   = params.fetch(:image)
        links   = params.fetch(:links)
        ports   = Array(params[:ports])
        volumes = Array(params[:volumes])
        name    = params.fetch(:name)
        cmd     = Array(params.fetch(:cmd))
        env     = params.fetch(:env)
        expose  = Array(params[:expose])

        run_cmd = %W(docker run --name #{name})
        run_cmd << "-d" if params[:detach]
        run_cmd += env.map { |k,v| ['-e', "#{k}=#{v}"] }
        run_cmd += expose.map { |p| ['--expose', "#{p}"] }
        run_cmd += links.map { |k, v| ['--link', "#{k}:#{v}"] }
        run_cmd += ports.map { |p| ['-p', p.to_s] }
        run_cmd += volumes.map { |v|
          v = v.to_s
          if v.include?(":") && @executor.windows?
            if v.index(":") != v.rindex(":")
              # If we have 2 colons, the host path is an absolute Windows URL
              # and we need to remove the colon from it
              host, _, guest = v.rpartition(":")
              host = "//" + host[0].downcase + host[2..-1]
              v = [host, guest].join(":")
            else
              # NOTE: Docker does not support UNC style paths (which also
              # means that there's no long path support). Hopefully this
              # will be fixed someday and the gsub below can be removed.
              host, guest = v.split(":", 2)
              # If using WSL within a drvfs file system
              # we want to continue to use linux pathing
              if (!ENV["VAGRANT_WSL_ENABLE_WINDOWS_ACCESS"])
                host = Vagrant::Util::Platform.windows_path(host)
                host.gsub!(/^[^A-Za-z]+/, "")
              end
              v = [host, guest].join(":")
            end
          end

          ['-v', v.to_s]
        }
        run_cmd += %W(--privileged) if params[:privileged]
        run_cmd += %W(-h #{params[:hostname]}) if params[:hostname]
        run_cmd << "-t" if params[:pty]
        run_cmd << "--rm=true" if params[:rm]
        run_cmd += params[:extra_args] if params[:extra_args]
        run_cmd += [image, cmd]

        execute(*run_cmd.flatten, **opts, &block).chomp.lines.last
      end

      def state(cid)
        case
        when running?(cid)
          :running
        when created?(cid)
          :stopped
        else
          :not_created
        end
      end

      def created?(cid)
        result = execute('docker', 'ps', '-a', '-q', '--no-trunc').to_s
        result =~ /^#{Regexp.escape cid}$/
      end

      def image?(id)
        result = execute('docker', 'images', '-q').to_s
        result =~ /^#{Regexp.escape(id)}$/
      end

      # Reads all current docker containers and determines what ports
      # are currently registered to be forwarded
      # {2222=>#<Set: {"127.0.0.1"}>, 8080=>#<Set: {"*"}>, 9090=>#<Set: {"*"}>}
      #
      # Note: This is this format because of what the builtin action for resolving colliding
      # port forwards expects.
      #
      # @return [Hash[Set]] used_ports - {forward_port: #<Set: {"host ip address"}>}
      def read_used_ports
        used_ports = Hash.new{|hash,key| hash[key] = Set.new}

        all_containers.each do |c|
          container_info = inspect_container(c)

          if container_info["HostConfig"]["PortBindings"]
            port_bindings = container_info["HostConfig"]["PortBindings"]
            next if port_bindings.empty? # Nothing defined, but not nil either

            port_bindings.each do |guest_port,host_mapping|
              host_mapping.each do |h|
                if h["HostIp"] == ""
                  hostip = "*"
                else
                  hostip = h["HostIp"]
                end
                hostport = h["HostPort"]
                used_ports[hostport].add(hostip)
              end
            end
          end
        end

        used_ports
      end

      def running?(cid)
        result = execute('docker', 'ps', '-q', '--no-trunc')
        result =~ /^#{Regexp.escape cid}$/m
      end

      def privileged?(cid)
        inspect_container(cid)['HostConfig']['Privileged']
      end

      def login(email, username, password, server)
        cmd = %W(docker login)
        cmd += ["-e", email] if email != ""
        cmd += ["-u", username] if username != ""
        cmd += ["-p", password] if password != ""
        cmd << server if server && server != ""

        execute(*cmd.flatten)
      end

      def logout(server)
        cmd = %W(docker logout)
        cmd << server if server && server != ""
        execute(*cmd.flatten)
      end

      def pull(image)
        execute('docker', 'pull', image)
      end

      def start(cid)
        if !running?(cid)
          execute('docker', 'start', cid)
          # This resets the cached information we have around, allowing `vagrant reload`s
          # to work properly
          @data = nil
        end
      end

      def stop(cid, timeout)
        if running?(cid)
          execute('docker', 'stop', '-t', timeout.to_s, cid)
        end
      end

      def rm(cid)
        if created?(cid)
          execute('docker', 'rm', '-f', '-v', cid)
        end
      end

      def rmi(id)
        execute('docker', 'rmi', id)
        return true
      rescue => e
        return false if e.to_s.include?("is using it")
        return false if e.to_s.include?("is being used")
        raise if !e.to_s.include?("No such image")
      end

      # Inspect the provided container
      #
      # @param [String] cid ID or name of container
      # @return [Hash]
      def inspect_container(cid)
        JSON.parse(execute('docker', 'inspect', cid)).first
      end

      # @return [Array<String>] list of all container IDs
      def all_containers
        execute('docker', 'ps', '-a', '-q', '--no-trunc').to_s.split
      end

      # @return [String] IP address of the docker bridge
      def docker_bridge_ip
        output = execute('/sbin/ip', '-4', 'addr', 'show', 'scope', 'global', 'docker0')
        if output =~ /^\s+inet ([0-9.]+)\/[0-9]+\s+/
          return $1.to_s
        else
          # TODO: Raise an user friendly message
          raise 'Unable to fetch docker bridge IP!'
        end
      end

      # @param [String] network - name of network to connect conatiner to
      # @param [String] cid - container id
      # @param [Array]  opts - An array of flags used for listing networks
      def connect_network(network, cid, opts=nil)
        command = ['docker', 'network', 'connect', network, cid].push(*opts)
        output = execute(*command)
        output
      end

      # @param [String] network - name of network to create
      # @param [Array]  opts - An array of flags used for listing networks
      def create_network(network, opts=nil)
        command = ['docker', 'network', 'create', network].push(*opts)
        output = execute(*command)
        output
      end

      # @param [String] network - name of network to disconnect container from
      # @param [String] cid - container id
      def disconnect_network(network, cid)
        command = ['docker', 'network', 'disconnect', network, cid, "--force"]
        output = execute(*command)
        output
      end

      # @param [Array]  networks - list of networks to inspect
      # @param [Array]  opts - An array of flags used for listing networks
      def inspect_network(network, opts=nil)
        command = ['docker', 'network', 'inspect'] + Array(network)
        command = command.push(*opts)
        output = execute(*command)
        begin
          JSON.load(output)
        rescue JSON::ParserError
          @logger.warn("Failed to parse network inspection of network: #{network}")
          @logger.debug("Failed network output content: `#{output.inspect}`")
          nil
        end
      end

      # @param [String] opts - Flags used for listing networks
      def list_network(*opts)
        command = ['docker', 'network', 'ls', *opts]
        output = execute(*command)
        output
      end

      # Will delete _all_ defined but unused networks in the docker engine. Even
      # networks not created by Vagrant.
      #
      # @param [Array] opts - An array of flags used for listing networks
      def prune_network(opts=nil)
        command = ['docker', 'network', 'prune', '--force'].push(*opts)
        output = execute(*command)
        output
      end

      # Delete network(s)
      #
      # @param [String] network - name of network to remove
      def rm_network(*network)
        command = ['docker', 'network', 'rm', *network]
        output = execute(*command)
        output
      end

      # @param [Array] opts - An array of flags used for listing networks
      def execute(*cmd, **opts, &block)
        @executor.execute(*cmd, **opts, &block)
      end

      # ######################
      # Docker network helpers
      # ######################

      # Determines if a given network has been defined through vagrant with a given
      # subnet string
      #
      # @param [String] subnet_string - Subnet to look for
      # @return [String] network name - Name of network with requested subnet.`nil` if not found
      def network_defined?(subnet_string)
        all_networks = list_network_names

        network_info = inspect_network(all_networks)
        network_info.each do |network|
          config = network["IPAM"]["Config"]
          if (config.size > 0 &&
            config.first["Subnet"] == subnet_string)
            @logger.debug("Found existing network #{network["Name"]} already configured with #{subnet_string}")
            return network["Name"]
          end
        end
        return nil
      end

      # Locate network which contains given address
      #
      # @param [String] address IP address
      # @return [String] network name
      def network_containing_address(address)
        names = list_network_names
        networks = inspect_network(names)
        return if !networks
        networks.each do |net|
          next if !net["IPAM"]
          config = net["IPAM"]["Config"]
          next if !config || config.size < 1
          config.each do |opts|
            subnet = IPAddr.new(opts["Subnet"])
            if subnet.include?(address)
              return net["Name"]
            end
          end
        end
        nil
      end

      # Looks to see if a docker network has already been defined
      # with the given name
      #
      # @param [String] network_name - name of network to look for
      # @return [Bool]
      def existing_named_network?(network_name)
        result = list_network_names
        result.any?{|net_name| net_name == network_name}
      end

      # @return [Array<String>] list of all docker networks
      def list_network_names
        list_network("--format={{.Name}}").split("\n").map(&:strip)
      end

      # Returns true or false if network is in use or not.
      # Nil if Vagrant fails to receive proper JSON from `docker network inspect`
      #
      # @param [String] network - name of network to look for
      # @return [Bool,nil]
      def network_used?(network)
        result = inspect_network(network)
        return nil if !result
        return result.first["Containers"].size > 0
      end

    end
  end
end
