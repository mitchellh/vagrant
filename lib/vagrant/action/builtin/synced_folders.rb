require "log4r"

require 'vagrant/util/platform'

require_relative "mixin_synced_folders"

module Vagrant
  module Action
    module Builtin
      # This middleware will setup the synced folders for the machine using
      # the appropriate synced folder plugin.
      class SyncedFolders
        include MixinSyncedFolders

        def initialize(app, env)
          @app    = app
          @logger = Log4r::Logger.new("vagrant::action::builtin::synced_folders")
        end

        def call(env)
          opts = {
            cached: !!env[:synced_folders_cached],
            config: env[:synced_folders_config],
          }

          @logger.info("SyncedFolders loading from cache: #{opts[:cached]}")
          folders = synced_folders(env[:machine], **opts)
          original_folders = folders

          folders.each do |impl_name, fs|
            @logger.info("Synced Folder Implementation: #{impl_name}")

            fs.each do |id, data|
              # Log every implementation and their paths
              @logger.info("  - #{id}: #{data[:hostpath]} => #{data[:guestpath]}")
            end
          end

          # Go through each folder and make sure to create it if
          # it does not exist on host
          folders.each do |_, fs|
            fs.each do |id, data|
              next if data[:hostpath_exact]

              data[:hostpath] = File.expand_path(
                data[:hostpath], env[:root_path])

              # Expand the symlink if this is a path that exists
              if File.file?(data[:hostpath])
                data[:hostpath] = File.realpath(data[:hostpath])
              end

              # Create the hostpath if it doesn't exist and we've been told to
              if !File.directory?(data[:hostpath]) && data[:create]
                @logger.info("Creating shared folder host directory: #{data[:hostpath]}")
                begin
                  Pathname.new(data[:hostpath]).mkpath
                rescue Errno::EACCES
                  raise Vagrant::Errors::SharedFolderCreateFailed,
                    path: data[:hostpath]
                end
              end

              if File.directory?(data[:hostpath])
                data[:hostpath] = File.realpath(data[:hostpath])
                data[:hostpath] = Util::Platform.fs_real_path(data[:hostpath]).to_s
              end
            end
          end

          # Build up the instances of the synced folders. We do this once
          # so that they can store state.
          folders = folders.map do |impl_name, fs|
            instance = plugins[impl_name.to_sym][0].new
            [instance, impl_name, fs]
          end

          # Go through each folder and prepare the folders
          folders.each do |impl, impl_name, fs|
            if !env[:synced_folders_disable]
              @logger.info("Invoking synced folder prepare for: #{impl_name}")
              impl.prepare(env[:machine], fs, impl_opts(impl_name, env))
            end
          end

          # Continue, we need the VM to be booted.
          @app.call(env)

          # Once booted, setup the folder contents
          folders.each do |impl, impl_name, fs|
            if !env[:synced_folders_disable]
              @logger.info("Invoking synced folder enable: #{impl_name}")
              synced_folder_opts = impl_opts(impl_name, env)
              # Add synced folder options to synced folder hash
              fs.each do |_, v|
                v.merge!(synced_folder_opts)
              end
              impl.enable(env[:machine], fs, synced_folder_opts)
              next
            end

            # We're disabling synced folders
            to_disable = {}
            fs.each do |id, data|
              next if !env[:synced_folders_disable].include?(id)
              to_disable[id] = data
            end

            @logger.info("Invoking synced folder disable: #{impl_name}")
            to_disable.each do |id, _|
              @logger.info("  - Disabling: #{id}")
            end
            impl.disable(env[:machine], to_disable, impl_opts(impl_name, env))
          end

          # If we disabled folders, we have to delete some from the
          # save, so we load the entire cached thing, and delete them.
          if env[:synced_folders_disable]
            all = synced_folders(env[:machine], cached: true)
            all.each do |impl, fs|
              fs.keys.each do |id|
                if env[:synced_folders_disable].include?(id)
                  fs.delete(id)
                end
              end
            end

            save_synced_folders(env[:machine], all)
          else
            save_opts = { merge: true }
            save_opts[:vagrantfile] = true if !opts[:config]

            # Save the synced folders
            save_synced_folders(env[:machine], original_folders, **save_opts)
          end

          # Persist the mounts by adding them to fstab (only if the guest is available)
          begin
            persist_mount = env[:machine].guest.capability?(:persist_mount_shared_folder)
          rescue Errors::MachineGuestNotReady
            persist_mount = false
          end
          if persist_mount
            # Persist the mounts by adding them to fstab
            if env[:machine].config.vm.allow_fstab_modification
              fstab_folders = original_folders
            else
              fstab_folders = nil
            end
            env[:machine].guest.capability(:persist_mount_shared_folder, fstab_folders)
          end
        end
      end
    end
  end
end
