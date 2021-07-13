module VagrantPlugins
  module GuestCygwin
    module Cap
      class FileSystem
        # Create a temporary file or directory on the guest
        #
        # @param [Vagrant::Machine] machine Vagrant guest machine
        # @param [Hash] opts Path options
        # @return [String] path to temporary file or directory
        def self.create_tmp_path(machine, opts)
          template = "vagrant-XXXXXX"
          if opts[:extension]
            template << opts[:extension].to_s
          end
          cmd = ["mktemp", "--tmpdir"]
          if opts[:type] == :directory
            cmd << "-d"
          end
          cmd << template
          tmp_path = ""
          machine.communicate.execute(cmd.join(" ")) do |type, data|
            if type == :stdout
              tmp_path << data
            end
          end
          tmp_path.strip
        end

        # Decompress tgz file on guest to given location
        #
        # @param [Vagrant::Machine] machine Vagrant guest machine
        # @param [String] compressed_file Path to compressed file on guest
        # @param [String] destination Path for decompressed files on guest
        def self.decompress_tgz(machine, compressed_file, destination, opts={})
          comm = machine.communicate
          extract_dir = create_tmp_path(machine, type: :directory)
          cmds = []
          if opts[:type] == :directory
            cmds << "mkdir -p '#{destination}'"
          else
            cmds << "mkdir -p '#{File.dirname(destination)}'"
          end
          cmds += [
            "tar -C '#{extract_dir}' -xzf '#{compressed_file}'",
            "mv '#{extract_dir}'/* '#{destination}'",
            "rm -f '#{compressed_file}'",
            "rm -rf '#{extract_dir}'"
          ]
          cmds.each{ |cmd| comm.execute(cmd) }
          true
        end

        # Decompress zip file on guest to given location
        #
        # @param [Vagrant::Machine] machine Vagrant guest machine
        # @param [String] compressed_file Path to compressed file on guest
        # @param [String] destination Path for decompressed files on guest
        def self.decompress_zip(machine, compressed_file, destination, opts={})
          comm = machine.communicate
          extract_dir = create_tmp_path(machine, type: :directory)
          cmds = []
          if opts[:type] == :directory
            cmds << "mkdir -p '#{destination}'"
          else
            cmds << "mkdir -p '#{File.dirname(destination)}'"
          end
          cmds += [
            "unzip '#{compressed_file}' -d '#{extract_dir}'",
            "mv '#{extract_dir}'/* '#{destination}'",
            "rm -f '#{compressed_file}'",
            "rm -rf '#{extract_dir}'"
          ]
          cmds.each{ |cmd| comm.execute(cmd) }
          true
        end
      end
    end
  end
end
