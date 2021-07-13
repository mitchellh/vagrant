require "fileutils"
require "log4r"

module VagrantPlugins
  module HyperV
    module Action
      class Import
        VALID_HD_EXTENSIONS = [".vhd".freeze, ".vhdx".freeze].freeze

        def initialize(app, env)
          @app = app
          @logger = Log4r::Logger.new("vagrant::hyperv::import")
        end

        def call(env)
          vm_dir = env[:machine].box.directory.join("Virtual Machines")
          hd_dir = env[:machine].box.directory.join("Virtual Hard Disks")

          if !vm_dir.directory? || !hd_dir.directory?
            @logger.error("Required virtual machine directory not found!")
            raise Errors::BoxInvalid, name: env[:machine].name
          end

          valid_config_ext = [".xml"]
          if env[:machine].provider.driver.has_vmcx_support?
            valid_config_ext << ".vmcx"
          end

          config_path = nil
          vm_dir.each_child do |file|
            if valid_config_ext.include?(file.extname.downcase)
              config_path = file
              break
            end
          end

          if !config_path
            @logger.error("Failed to locate box configuration path")
            raise Errors::BoxInvalid, name: env[:machine].name
          else
            @logger.info("Found box configuration path: #{config_path}")
          end

          # Fixes: 10831: This original logic with image_path does not work, if there is more than one disk (we cannot rely on the first disk
          # indicating the destination directory, and any additional disks overwrite this)
          # A better approach is passing the destination directory (instead of guessing it), to powershell
          # and use the HyperV module to derive the needed paths from the VMConfig, which is used by the powershell
          # code anyway to find the necessary drives.
          image_path = nil
          source_disk_files = []
          hd_dir.each_child do |file|
            if VALID_HD_EXTENSIONS.include?(file.extname.downcase)
              image_path = file
              # source_disk_files.push(Vagrant::Util::Platform.wsl_to_windows_path(file).gsub("/", "\\"))
              source_disk_files.push(file.to_s)
              @logger.info("Use original disk from box: #{file.to_s}")
            end
          end

          if !image_path
            @logger.error("Failed to locate any disks in this box.")
            raise Errors::BoxInvalid, name: env[:machine].name
          else
          end

          env[:ui].output("Importing a Hyper-V instance")
          dest_dir = env[:machine].data_dir.join("Virtual Hard Disks").to_s
          @logger.info("Putting all disk drives into  #{dest_dir}")

          options = {
            "VMConfigFile" => Vagrant::Util::Platform.wsl_to_windows_path(config_path).gsub("/", "\\"),
            "DestinationDirectory" => Vagrant::Util::Platform.wsl_to_windows_path(dest_dir).gsub("/", "\\"),
            "DataPath" => Vagrant::Util::Platform.wsl_to_windows_path(env[:machine].data_dir).gsub("/", "\\"),
            "LinkedClone" => !!env[:machine].provider_config.linked_clone,
            "VMName" => env[:machine].provider_config.vmname,
            # Catenate the values using a "|" character, withstood all attempts to use a standard representation of the array or JSON or similar
            "SourceDiskFilesString" => source_disk_files.collect {
              |item|
              Vagrant::Util::Platform.wsl_to_windows_path(item).gsub("/", "\\")
            }.join("|"),
          }

          env[:ui].detail("Creating and registering the VM...")
          server = env[:machine].provider.driver.import(options)

          env[:ui].detail("Successfully imported VM")
          env[:machine].id = server["id"]
          @app.call(env)
        end
      end
    end
  end
end
