require "json"
require "pathname"
require "securerandom"
require "thread"

require "vagrant/util/silence_warnings"

module Vagrant
  # MachineIndex is able to manage the index of created Vagrant environments
  # in a central location.
  #
  # The MachineIndex stores a mapping of UUIDs to basic information about
  # a machine. The UUIDs are stored with the Vagrant environment and are
  # looked up in the machine index.
  #
  # The MachineIndex stores information such as the name of a machine,
  # the directory it was last seen at, its last known state, etc. Using
  # this information, we can load the entire {Machine} object for a machine,
  # or we can just display metadata if needed.
  #
  # The internal format of the data file is currently JSON in the following
  # structure:
  #
  #   {
  #     "version": 1,
  #     "machines": {
  #       "uuid": {
  #         "name": "foo",
  #         "provider": "vmware_fusion",
  #         "data_path": "/path/to/data/dir",
  #         "vagrantfile_path": "/path/to/Vagrantfile",
  #         "state": "running",
  #         "updated_at": "2014-03-02 11:11:44 +0100"
  #       }
  #     }
  #   }
  #
  class MachineIndex
    include Enumerable

    # Initializes a MachineIndex at the given file location.
    #
    # @param [Pathname] data_dir Path to the directory where data for the
    #   index can be stored. This folder should exist and must be writable.
    def initialize(data_dir)
      @data_dir   = data_dir
      @index_file = data_dir.join("index")
      @lock       = Monitor.new
      @machines  = {}
      @machine_locks = {}

      with_index_lock do
        unlocked_reload
      end
    end

    # Deletes a machine by UUID.
    #
    # The machine being deleted with this UUID must either be locked
    # by this index or must be unlocked.
    #
    # @param [Entry] entry The entry to delete.
    # @return [Boolean] true if delete is successful
    def delete(entry)
      return true if !entry.id

      @lock.synchronize do
        with_index_lock do
          return true if !@machines[entry.id]

          # If we don't have the lock, then we need to acquire it.
          if !@machine_locks[entry.id]
            raise "Unlocked delete on machine: #{entry.id}"
          end

          # Reload so we have the latest data, then delete and save
          unlocked_reload
          @machines.delete(entry.id)
          unlocked_save

          # Release access on this machine
          unlocked_release(entry.id)
        end
      end

      true
    end

    # Iterate over every machine in the index. The yielded {Entry} objects
    # will NOT be locked, so you'll have to call {#get} manually to acquire
    # the lock on them.
    def each(reload=false)
      if reload
        @lock.synchronize do
          with_index_lock do
            unlocked_reload
          end
        end
      end

      @machines.each do |uuid, data|
        yield Entry.new(uuid, data.merge("id" => uuid))
      end
    end

    # Accesses a machine by UUID and returns a {MachineIndex::Entry}
    #
    # The entry returned is locked and can't be read again or updated by
    # this process or any other. To unlock the machine, call {#release}
    # with the entry.
    #
    # You can only {#set} an entry (update) when the lock is held.
    #
    # @param [String] uuid UUID for the machine to access.
    # @return [MachineIndex::Entry]
    def get(uuid)
      entry = nil

      @lock.synchronize do
        with_index_lock do
          # Reload the data
          unlocked_reload

          data = find_by_prefix(uuid)
          return nil if !data
          uuid = data["id"]

          entry = Entry.new(uuid, data)

          # Lock this machine
          lock_file = lock_machine(uuid)
          if !lock_file
            raise Errors::MachineLocked,
              name: entry.name,
              provider: entry.provider
          end

          @machine_locks[uuid] = lock_file
        end
      end

      entry
    end

    # Tests if the index has the given UUID.
    #
    # @param [String] uuid
    # @return [Boolean]
    def include?(uuid)
      @lock.synchronize do
        with_index_lock do
          unlocked_reload
          return !!find_by_prefix(uuid)
        end
      end
    end

    # Releases an entry, unlocking it.
    #
    # This is an idempotent operation. It is safe to call this even if you're
    # unsure if an entry is locked or not.
    #
    # After calling this, the previous entry should no longer be used.
    #
    # @param [Entry] entry
    def release(entry)
      @lock.synchronize do
        unlocked_release(entry.id)
      end
    end

    # Creates/updates an entry object and returns the resulting entry.
    #
    # If the entry was new (no UUID), then the UUID will be set on the
    # resulting entry and can be used. Additionally, the a lock will
    # be created for the resulting entry, so you must {#release} it
    # if you want others to be able to access it.
    #
    # If the entry isn't new (has a UUID). then this process must hold
    # that entry's lock or else this set will fail.
    #
    # @param [Entry] entry
    # @return [Entry]
    def set(entry)
      # Get the struct and update the updated_at attribute
      struct = entry.to_json_struct

      # Set an ID if there isn't one already set
      id     = entry.id

      @lock.synchronize do
        with_index_lock do
          # Reload so we have the latest machine data. This allows other
          # processes to update their own machines without conflicting
          # with our own.
          unlocked_reload

          # If we don't have a machine ID, try to look one up
          if !id
            self.each do |other|
              if entry.name == other.name &&
                entry.provider == other.provider &&
                entry.local_data_path.to_s == other.local_data_path.to_s &&
                entry.vagrantfile_path.to_s == other.vagrantfile_path.to_s
                id = other.id
                break
              end
            end

            # If we still don't have an ID, generate a random one
            id = SecureRandom.uuid.gsub("-", "") if !id

            # Get a lock on this machine
            lock_file = lock_machine(id)
            if !lock_file
              raise "Failed to lock new machine: #{entry.name}"
            end

            @machine_locks[id] = lock_file
          end

          if !@machine_locks[id]
            raise "Unlocked write on machine: #{id}"
          end

          # Set our machine and save
          @machines[id] = struct
          unlocked_save
        end
      end

      Entry.new(id, struct)
    end

    # Reinsert a machine into the global index if it has
    # a valid existing uuid but does not currently exist
    # in the index.
    #
    # @param [Entry] entry
    # @return [Entry]
    def recover(entry)
      @lock.synchronize do
        with_index_lock do
          # Reload the data
          unlocked_reload
          # Don't recover if entry already exists in the global
          return entry if find_by_prefix(entry.id)

          lock_file = lock_machine(entry.id)
          if !lock_file
            raise Errors::MachineLocked,
              name: entry.name,
              provider: entry.provider
          end
          @machine_locks[entry.id] = lock_file
        end
      end
      return set(entry)
    end

    protected

    # Finds a machine where the UUID is prefixed by the given string.
    #
    # @return [Hash]
    def find_by_prefix(prefix)
      return if !prefix || prefix == ""
      @machines.each do |uuid, data|
        return data.merge("id" => uuid) if uuid.start_with?(prefix)
      end

      nil
    end

    # Locks a machine exclusively to us, returning the file handle
    # that holds the lock.
    #
    # If the lock cannot be acquired, then nil is returned.
    #
    # This should be called within an index lock.
    #
    # @return [File]
    def lock_machine(uuid)
      lock_path = @data_dir.join("#{uuid}.lock")
      lock_file = lock_path.open("w+")
      if lock_file.flock(File::LOCK_EX | File::LOCK_NB) === false
        lock_file.close
        lock_file = nil
      end

      lock_file
    end

    # Releases a local lock on a machine. This does not acquire any locks
    # so make sure to lock around it.
    #
    # @param [String] id
    def unlocked_release(id)
      lock_file = @machine_locks[id]
      if lock_file
        lock_file.close
        begin
          File.delete(lock_file.path)
        rescue Errno::EACCES
          # Another process is probably opened it, no problem.
        end

        @machine_locks.delete(id)
      end
    end

    # This will reload the data without locking the index. It is assumed
    # the caller with lock the index outside of this call.
    #
    # @param [File] f
    def unlocked_reload
      return if !@index_file.file?

      data = nil
      begin
        data = JSON.load(@index_file.read)
      rescue JSON::ParserError
        raise Errors::CorruptMachineIndex, path: @index_file.to_s
      end

      if data
        if !data["version"] || data["version"].to_i != 1
          raise Errors::CorruptMachineIndex, path: @index_file.to_s
        end

        @machines = data["machines"] || {}
      end
    end

    # Saves the index.
    def unlocked_save
      @index_file.open("w") do |f|
        f.write(JSON.dump({
          "version"  => 1,
          "machines" => @machines,
        }))
      end
    end


    # This will hold a lock to the index so it can be read or updated.
    def with_index_lock
      lock_path = "#{@index_file}.lock"
      File.open(lock_path, "w+") do |f|
        f.flock(File::LOCK_EX)
        yield
      end
    end

    # An entry in the MachineIndex.
    class Entry
      # The unique ID for this entry. This is _not_ the ID for the
      # machine itself (which is provider-specific and in the data directory).
      #
      # @return [String]
      attr_reader :id

      # The path for the "local data" directory for the environment.
      #
      # @return [Pathname]
      attr_accessor :local_data_path

      # The name of the machine.
      #
      # @return [String]
      attr_accessor :name

      # The name of the provider.
      #
      # @return [String]
      attr_accessor :provider

      # The last known state of this machine.
      #
      # @return [String]
      attr_accessor :state

      # The valid Vagrantfile filenames for this environment.
      #
      # @return [Array<String>]
      attr_accessor :vagrantfile_name

      # The path to the Vagrantfile that manages this machine.
      #
      # @return [Pathname]
      attr_accessor :vagrantfile_path

      # The last time this entry was updated.
      #
      # @return [DateTime]
      attr_reader :updated_at

      # Extra data to store with the index entry. This can be anything
      # and is treated like a general global state bag.
      #
      # @return [Hash]
      attr_accessor :extra_data

      # Initializes an entry.
      #
      # The parameter given should be nil if this is being created
      # publicly.
      def initialize(id=nil, raw=nil)
        @extra_data = {}

        # Do nothing if we aren't given a raw value. Otherwise, parse it.
        return if !raw

        @id               = id
        @local_data_path  = raw["local_data_path"]
        @name             = raw["name"]
        @provider         = raw["provider"]
        @state            = raw["state"]
        @vagrantfile_name = raw["vagrantfile_name"]
        @vagrantfile_path = raw["vagrantfile_path"]
        # TODO(mitchellh): parse into a proper datetime
        @updated_at       = raw["updated_at"]
        @extra_data       = raw["extra_data"] || {}

        # Be careful with the paths
        @local_data_path = nil  if @local_data_path == ""
        @vagrantfile_path = nil if @vagrantfile_path == ""

        # Convert to proper types
        @local_data_path = Pathname.new(@local_data_path) if @local_data_path
        @vagrantfile_path = Pathname.new(@vagrantfile_path) if @vagrantfile_path
      end

      # Returns boolean true if this entry appears to be valid.
      # The criteria for being valid:
      #
      #   * Vagrantfile directory exists
      #   * Vagrant environment contains a machine with this
      #     name and provider.
      #
      # This method is _slow_. It should be used with care.
      #
      # @param [Pathname] home_path The home path for the Vagrant
      #   environment.
      # @return [Boolean]
      def valid?(home_path)
        return false if !vagrantfile_path
        return false if !vagrantfile_path.directory?

        # Create an environment so we can determine the active
        # machines...
        found = false
        env = vagrant_env(home_path)
        env.active_machines.each do |name, provider|
          if name.to_s == self.name.to_s &&
            provider.to_s == self.provider.to_s
            found = true
            break
          end
        end

        # If an active machine of the same name/provider was not
        # found, it is already false.
        return false if !found

        # Get the machine
        machine = nil
        begin
          machine = env.machine(self.name.to_sym, self.provider.to_sym)
        rescue Errors::MachineNotFound
          return false
        end

        # Refresh the machine state
        return false if machine.state.id == MachineState::NOT_CREATED_ID

        true
      end

      # Creates a {Vagrant::Environment} for this entry.
      #
      # @return [Vagrant::Environment]
      def vagrant_env(home_path, opts={})
        Vagrant::Util::SilenceWarnings.silence! do
          Environment.new({
            cwd: @vagrantfile_path,
            home_path: home_path,
            local_data_path: @local_data_path,
            vagrantfile_name: @vagrantfile_name,
          }.merge(opts))
        end
      end

      # Converts to the structure used by the JSON
      def to_json_struct
        {
          "local_data_path"  => @local_data_path.to_s,
          "name"             => @name,
          "provider"         => @provider,
          "state"            => @state,
          "vagrantfile_name" => @vagrantfile_name,
          "vagrantfile_path" => @vagrantfile_path.to_s,
          "updated_at"       => @updated_at,
          "extra_data"       => @extra_data,
        }
      end
    end
  end
end
