require "log4r"
require 'optparse'
require "thread"

require "vagrant/action/builtin/mixin_synced_folders"
require "vagrant/util/busy"
require "vagrant/util/platform"

require_relative "../helper"

# This is to avoid a bug in nio 1.0.0. Remove around nio 1.0.1
if Vagrant::Util::Platform.windows?
  ENV["NIO4R_PURE"] = "1"
end

require "listen"

module VagrantPlugins
  module SyncedFolderRSync
    module Command
      class RsyncAuto < Vagrant.plugin("2", :command)
        include Vagrant::Action::Builtin::MixinSyncedFolders

        def self.synopsis
          "syncs rsync synced folders automatically when files change"
        end

        def execute
          @logger = Log4r::Logger.new("vagrant::commands::rsync-auto")

          options = {}
          opts = OptionParser.new do |o|
            o.banner = "Usage: vagrant rsync-auto [vm-name]"
            o.separator ""
            o.separator "Options:"
            o.separator ""

            o.on("--[no-]poll", "Force polling filesystem (slow)") do |poll|
              options[:poll] = poll
            end
          end

          # Parse the options and return if we don't have any target.
          argv = parse_options(opts)
          return if !argv

          # Build up the paths that we need to listen to.
          paths = {}
          ignores = []
          with_target_vms(argv) do |machine|
            cached = synced_folders(machine, cached: true)
            fresh  = synced_folders(machine)
            diff   = synced_folders_diff(cached, fresh)
            if !diff[:added].empty?
              machine.ui.warn(I18n.t("vagrant.rsync_auto_new_folders"))
            end

            folders = cached[:rsync]
            next if !folders || folders.empty?

            # Get the SSH info for this machine so we can do an initial
            # sync to the VM.
            communicator_info = machine.communicator_info
            if communicator_info
              machine.ui.info(I18n.t("vagrant.rsync_auto_initial"))
              folders.each do |id, folder_opts|
                RsyncHelper.rsync_single(machine, communicator_info, folder_opts)
              end
            end

            folders.each do |id, folder_opts|
              # If we marked this folder to not auto sync, then
              # don't do it.
              next if folder_opts.has_key?(:auto) && !folder_opts[:auto]

              hostpath = folder_opts[:hostpath]
              hostpath = File.expand_path(hostpath, machine.env.root_path)
              paths[hostpath] ||= []
              paths[hostpath] << {
                id: id,
                machine: machine,
                opts:    folder_opts,
              }

              if folder_opts[:exclude]
                Array(folder_opts[:exclude]).each do |pattern|
                  ignores << RsyncHelper.exclude_to_regexp(hostpath, pattern.to_s)
                end
              end
            end
          end

          # Exit immediately if there is nothing to watch
          if paths.empty?
            @env.ui.info(I18n.t("vagrant.rsync_auto_no_paths"))
            return 1
          end

          # Output to the user what paths we'll be watching
          paths.keys.sort.each do |path|
            paths[path].each do |path_opts|
              path_opts[:machine].ui.info(I18n.t(
                "vagrant.rsync_auto_path",
                path: path.to_s,
              ))
            end
          end

          @logger.info("Listening to paths: #{paths.keys.sort.inspect}")
          @logger.info("Ignoring #{ignores.length} paths:")
          ignores.each do |ignore|
            @logger.info("  -- #{ignore.to_s}")
          end
          @logger.info("Listening via: #{Listen::Adapter.select.inspect}")
          callback = method(:callback).to_proc.curry[paths]
          listopts = { ignore: ignores, force_polling: !!options[:poll] }
          listener = Listen.to(*paths.keys, listopts, &callback)

          # Create the callback that lets us know when we've been interrupted
          queue    = Queue.new
          callback = lambda do
            # This needs to execute in another thread because Thread
            # synchronization can't happen in a trap context.
            Thread.new { queue << true }
          end

          # Run the listener in a busy block so that we can cleanly
          # exit once we receive an interrupt.
          Vagrant::Util::Busy.busy(callback) do
            listener.start
            queue.pop
            listener.stop if listener.listen?
          end

          0
        end

        # This is the callback that is called when any changes happen
        def callback(paths, modified, added, removed)
          @logger.info("File change callback called!")
          @logger.info("  - Modified: #{modified.inspect}")
          @logger.info("  - Added: #{added.inspect}")
          @logger.info("  - Removed: #{removed.inspect}")

          tosync = []
          paths.each do |hostpath, folders|
            # Find out if this path should be synced
            found = catch(:done) do
              [modified, added, removed].each do |changed|
                changed.each do |listenpath|
                  throw :done, true if listenpath.start_with?(hostpath)
                end
              end

              # Make sure to return false if all else fails so that we
              # don't sync to this machine.
              false
            end

            # If it should be synced, store it for later
            tosync << folders if found
          end

          # Sync all the folders that need to be synced
          tosync.each do |folders|
            folders.each do |opts|
              # Reload so we get the latest ID
              opts[:machine].reload
              if !opts[:machine].id || opts[:machine].id == ""
                # Skip since we can't get SSH info without an ID
                next
              end

              communicator_info = opts[:machine].communicator_info
              begin
                RsyncHelper.rsync_single(opts[:machine], communicator_info, opts[:opts])
              rescue Vagrant::Errors::MachineGuestNotReady
                # Error communicating to the machine, probably a reload or
                # halt is happening. Just notify the user but don't fail out.
                opts[:machine].ui.error(I18n.t(
                  "vagrant.rsync_communicator_not_ready_callback"))
              end
            end
          end
        end
      end
    end
  end
end
