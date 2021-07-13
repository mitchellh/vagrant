require File.expand_path("../../base", __FILE__)
require "json"
require "pathname"
require "tempfile"
require "tmpdir"

require "vagrant/util/file_mode"
require "vagrant/util/platform"

describe Vagrant::Environment do
  include_context "unit"
  include_context "capability_helpers"

  let(:env) do
    isolated_environment.tap do |e|
      e.box3("base", "1.0", :virtualbox)
      e.vagrantfile <<-VF
      Vagrant.configure("2") do |config|
        config.vm.box = "base"
      end
      VF
    end
  end

  let(:instance)  { env.create_vagrant_env }
  subject { instance }

  describe "#can_install_provider?" do
    let(:plugin_hosts) { {} }
    let(:plugin_host_caps) { {} }

    before do
      m = Vagrant.plugin("2").manager
      allow(m).to receive(:hosts).and_return(plugin_hosts)
      allow(m).to receive(:host_capabilities).and_return(plugin_host_caps)

      # Detect the host
      env.vagrantfile <<-VF
      Vagrant.configure("2") do |config|
        config.vagrant.host = nil
      end
      VF

      # Setup the foo host by default
      plugin_hosts[:foo] = [detect_class(true), nil]
    end

    it "should return whether it can install or not" do
      plugin_host_caps[:foo] = { provider_install_foo: Class }

      expect(subject.can_install_provider?(:foo)).to be(true)
      expect(subject.can_install_provider?(:bar)).to be(false)
    end
  end

  describe "#install_provider" do
    let(:host) { double(:host) }

    before do
      allow(subject).to receive(:host).and_return(host)
    end

    it "should install the correct provider" do
      expect(host).to receive(:capability).with(:provider_install_foo)

      subject.install_provider(:foo)
    end
  end

  describe "#gems_path" do
    it "is set to Vagrant::Bundler defined path" do
      instance = described_class.new
      expect(instance.gems_path).to eq(Vagrant::Bundler.instance.plugin_gem_path)
    end
  end

  describe "#home_path" do
    it "is set to the home path given" do
      Dir.mktmpdir("vagrant-test-env-home-path-given") do |dir|
        instance = described_class.new(home_path: dir)
        expect(instance.home_path).to eq(Pathname.new(dir))
      end
    end

    it "is set to the environmental variable VAGRANT_HOME" do
      Dir.mktmpdir("vagrant-test-env-home-env-var") do |dir|
        instance = with_temp_env("VAGRANT_HOME" => dir.to_s) do
          described_class.new
        end

        expect(instance.home_path).to eq(Pathname.new(dir))
      end
    end

    it "throws an exception if inaccessible", skip_windows: true do
      expect {
        described_class.new(home_path: "/")
      }.to raise_error(Vagrant::Errors::HomeDirectoryNotAccessible)
    end

    context "with setup version file" do
      it "creates a setup version flie" do
        path = subject.home_path.join("setup_version")
        expect(path).to be_file
        expect(path.read).to eq(Vagrant::Environment::CURRENT_SETUP_VERSION)
      end

      it "is okay if it has the current version" do
        Dir.mktmpdir("vagrant-test-env-current-version") do |dir|
          Pathname.new(dir).join("setup_version").open("w") do |f|
            f.write(Vagrant::Environment::CURRENT_SETUP_VERSION)
          end

          instance = described_class.new(home_path: dir)
          path = instance.home_path.join("setup_version")
          expect(path).to be_file
          expect(path.read).to eq(Vagrant::Environment::CURRENT_SETUP_VERSION)
        end
      end

      it "raises an exception if the version is newer than ours" do
        Dir.mktmpdir("vagrant-test-env-newer-version") do |dir|
          Pathname.new(dir).join("setup_version").open("w") do |f|
            f.write("100.5")
          end

          expect { described_class.new(home_path: dir) }.
            to raise_error(Vagrant::Errors::HomeDirectoryLaterVersion)
        end
      end

      it "raises an exception if there is an unknown home directory version" do
        Dir.mktmpdir("vagrant-test-env-unknown-home") do |dir|
          Pathname.new(dir).join("setup_version").open("w") do |f|
            f.write("0.7")
          end

          expect { described_class.new(home_path: dir) }.
            to raise_error(Vagrant::Errors::HomeDirectoryUnknownVersion)
        end
      end
    end

    context "upgrading a v1.1 directory structure" do
      let(:env) { isolated_environment }

      before do
        env.homedir.join("setup_version").open("w") do |f|
          f.write("1.1")
        end

        allow_any_instance_of(Vagrant::UI::Silent).
          to receive(:ask)
      end

      it "replaces the setup version with the new version" do
        expect(subject.home_path.join("setup_version").read).
          to eq(Vagrant::Environment::CURRENT_SETUP_VERSION)
      end

      it "moves the boxes into the new directory structure" do
        # Kind of hacky but avoids two instantiations of BoxCollection
        allow(Vagrant::Environment).to receive(:boxes)
          .and_return(double("boxes"))

        collection = double("collection")
        expect(Vagrant::BoxCollection).to receive(:new).with(
          env.homedir.join("boxes"), anything).twice.and_return(collection)
        expect(collection).to receive(:upgrade_v1_1_v1_5).once
        subject
      end
    end
  end

  describe "#host" do
    let(:plugin_hosts) { {} }
    let(:plugin_host_caps) { {} }

    before do
      m = Vagrant.plugin("2").manager
      allow(m).to receive(:hosts).and_return(plugin_hosts)
      allow(m).to receive(:host_capabilities).and_return(plugin_host_caps)
    end

    it "should default to some host even if there are none" do
      env.vagrantfile <<-VF
      Vagrant.configure("2") do |config|
        config.vagrant.host = nil
      end
      VF

      expect(subject.host).to be
    end

    it "should attempt to detect a host if no host is set" do
      env.vagrantfile <<-VF
      Vagrant.configure("2") do |config|
        config.vagrant.host = nil
      end
      VF

      plugin_hosts[:foo] = [detect_class(true), nil]
      plugin_host_caps[:foo] = { bar: Class }

      result = subject.host
      expect(result.capability?(:bar)).to be(true)
    end

    it "should attempt to detect a host if host is :detect" do
      env.vagrantfile <<-VF
      Vagrant.configure("2") do |config|
        config.vagrant.host = :detect
      end
      VF

      plugin_hosts[:foo] = [detect_class(true), nil]
      plugin_host_caps[:foo] = { bar: Class }

      result = subject.host
      expect(result.capability?(:bar)).to be(true)
    end

    it "should use an exact host if specified" do
      env.vagrantfile <<-VF
      Vagrant.configure("2") do |config|
        config.vagrant.host = "foo"
      end
      VF

      plugin_hosts[:foo] = [detect_class(false), nil]
      plugin_hosts[:bar] = [detect_class(true), nil]
      plugin_host_caps[:foo] = { bar: Class }

      result = subject.host
      expect(result.capability?(:bar)).to be(true)
    end

    it "should raise an error if an exact match was specified but not found" do
      env.vagrantfile <<-VF
      Vagrant.configure("2") do |config|
        config.vagrant.host = "bar"
      end
      VF

      expect { subject.host }.
        to raise_error(Vagrant::Errors::HostExplicitNotDetected)
    end
  end

  describe "#lock" do
    def lock_count
      subject.data_dir.
        children.
        find_all { |c| c.to_s.end_with?("lock") }.
        length
    end

    it "does nothing if no block is given" do
      subject.lock
    end

    it "locks the environment" do
      another = env.create_vagrant_env
      raised  = false

      subject.lock do
        begin
          another.lock {}
        rescue Vagrant::Errors::EnvironmentLockedError
          raised = true
        end
      end

      expect(raised).to be(true)
    end

    it "allows nested locks on the same environment" do
      success = false

      subject.lock do
        subject.lock do
          success = true
        end
      end

      expect(success).to be(true)
    end

    it "cleans up all lock files" do
      inner_count = nil

      expect(lock_count).to eq(0)
      subject.lock do
        inner_count = lock_count
      end

      expect(inner_count).to_not be_nil
      expect(inner_count).to eq(2)
      expect(lock_count).to eq(1)
    end
  end

  describe "#machine" do
    # A helper to register a provider for use in tests.
    def register_provider(name, config_class=nil, options=nil)
      provider_cls = Class.new(VagrantTests::DummyProvider)

      register_plugin("2") do |p|
        p.provider(name, options) { provider_cls }

        if config_class
          p.config(name, :provider) { config_class }
        end
      end

      provider_cls
    end

    it "should return a machine object with the correct provider" do
      # Create a provider
      foo_provider = register_provider("foo")

      # Create the configuration
      isolated_env = isolated_environment do |e|
        e.vagrantfile(<<-VF)
Vagrant.configure("2") do |config|
  config.vm.box = "base"
  config.vm.define "foo"
end
VF

        e.box3("base", "1.0", :foo)
      end

      # Verify that we can get the machine
      env = isolated_env.create_vagrant_env
      machine = env.machine(:foo, :foo)
      expect(machine).to be_kind_of(Vagrant::Machine)
      expect(machine.name).to eq(:foo)
      expect(machine.provider).to be_kind_of(foo_provider)
      expect(machine.provider_config).to be_nil
    end

    it "should return a machine object with the machine configuration" do
      # Create a provider
      foo_config = Class.new(Vagrant.plugin("2", :config)) do
        attr_accessor :value
      end

      foo_provider = register_provider("foo", foo_config)

      # Create the configuration
      isolated_env = isolated_environment do |e|
        e.vagrantfile(<<-VF)
Vagrant.configure("2") do |config|
  config.vm.box = "base"
  config.vm.define "foo"

  config.vm.provider :foo do |fooconfig|
    fooconfig.value = 100
  end
end
VF

        e.box3("base", "1.0", :foo)
      end

      # Verify that we can get the machine
      env = isolated_env.create_vagrant_env
      machine = env.machine(:foo, :foo)
      expect(machine).to be_kind_of(Vagrant::Machine)
      expect(machine.name).to eq(:foo)
      expect(machine.provider).to be_kind_of(foo_provider)
      expect(machine.provider_config.value).to eq(100)
    end

    it "should cache the machine objects by name and provider" do
      # Create a provider
      foo_provider = register_provider("foo")
      bar_provider = register_provider("bar")

      # Create the configuration
      isolated_env = isolated_environment do |e|
        e.vagrantfile(<<-VF)
Vagrant.configure("2") do |config|
  config.vm.box = "base"
  config.vm.define "vm1"
  config.vm.define "vm2"
end
VF

        e.box3("base", "1.0", :foo)
        e.box3("base", "1.0", :bar)
      end

      env = isolated_env.create_vagrant_env
      vm1_foo = env.machine(:vm1, :foo)
      vm1_bar = env.machine(:vm1, :bar)
      vm2_foo = env.machine(:vm2, :foo)

      expect(vm1_foo).to eql(env.machine(:vm1, :foo))
      expect(vm1_bar).to eql(env.machine(:vm1, :bar))
      expect(vm1_foo).not_to eql(vm1_bar)
      expect(vm2_foo).to eql(env.machine(:vm2, :foo))
    end

    it "should load a machine without a box" do
      register_provider("foo")

      environment = isolated_environment do |env|
        env.vagrantfile(<<-VF)
Vagrant.configure("2") do |config|
  config.vm.box = "i-dont-exist"
end
VF
      end

      env = environment.create_vagrant_env
      machine = env.machine(:default, :foo)
      expect(machine.box).to be_nil
    end

    it "should load the machine configuration" do
      register_provider("foo")

      environment = isolated_environment do |env|
        env.vagrantfile(<<-VF)
Vagrant.configure("2") do |config|
  config.ssh.port = 1
  config.vm.box = "base"

  config.vm.define "vm1" do |inner|
    inner.ssh.port = 100
  end
end
VF

        env.box3("base", "1.0", :foo)
      end

      env = environment.create_vagrant_env
      machine = env.machine(:vm1, :foo)
      expect(machine.config.ssh.port).to eq(100)
      expect(machine.config.vm.box).to eq("base")
    end

    it "should load the box configuration for a box" do
      register_provider("foo")

      environment = isolated_environment do |env|
        env.vagrantfile(<<-VF)
Vagrant.configure("2") do |config|
  config.vm.box = "base"
end
VF

        env.box3("base", "1.0", :foo, vagrantfile: <<-VF)
Vagrant.configure("2") do |config|
  config.ssh.port = 100
end
VF
      end

      env = environment.create_vagrant_env
      machine = env.machine(:default, :foo)
      expect(machine.config.ssh.port).to eq(100)
    end

    it "should load the box configuration for a box and custom Vagrantfile name" do
      register_provider("foo")

      environment = isolated_environment do |env|
        env.file("some_other_name", <<-VF)
Vagrant.configure("2") do |config|
  config.vm.box = "base"
end
VF

        env.box3("base", "1.0", :foo, vagrantfile: <<-VF)
Vagrant.configure("2") do |config|
  config.ssh.port = 100
end
VF
      end

      env = with_temp_env("VAGRANT_VAGRANTFILE" => "some_other_name") do
        environment.create_vagrant_env
      end

      machine = env.machine(:default, :foo)
      expect(machine.config.ssh.port).to eq(100)
    end

    it "should load the box configuration for other formats for a box" do
      register_provider("foo", nil, box_format: "bar")

      environment = isolated_environment do |env|
        env.vagrantfile(<<-VF)
Vagrant.configure("2") do |config|
  config.vm.box = "base"
end
VF

        env.box3("base", "1.0", :bar, vagrantfile: <<-VF)
Vagrant.configure("2") do |config|
  config.ssh.port = 100
end
VF
      end

      env = environment.create_vagrant_env
      machine = env.machine(:default, :foo)
      expect(machine.config.ssh.port).to eq(100)
    end

    it "prefer sooner formats when multiple box formats are available" do
      register_provider("foo", nil, box_format: ["fA", "fB"])

      environment = isolated_environment do |env|
        env.vagrantfile(<<-VF)
Vagrant.configure("2") do |config|
  config.vm.box = "base"
end
VF

        env.box3("base", "1.0", :fA, vagrantfile: <<-VF)
Vagrant.configure("2") do |config|
  config.ssh.port = 100
end
VF

        env.box3("base", "1.0", :fB, vagrantfile: <<-VF)
Vagrant.configure("2") do |config|
  config.ssh.port = 200
end
VF
      end

      env = environment.create_vagrant_env
      machine = env.machine(:default, :foo)
      expect(machine.config.ssh.port).to eq(100)
    end

    it "should load the proper version of a box" do
      register_provider("foo")

      environment = isolated_environment do |env|
        env.vagrantfile(<<-VF)
Vagrant.configure("2") do |config|
  config.vm.box = "base"
  config.vm.box_version = "~> 1.2"
end
VF

        env.box3("base", "1.0", :foo, vagrantfile: <<-VF)
Vagrant.configure("2") do |config|
  config.ssh.port = 100
end
VF

        env.box3("base", "1.5", :foo, vagrantfile: <<-VF)
Vagrant.configure("2") do |config|
  config.ssh.port = 200
end
VF
      end

      env = environment.create_vagrant_env
      machine = env.machine(:default, :foo)
      expect(machine.config.ssh.port).to eq(200)
    end

    it "should load the provider override if set" do
      register_provider("bar")
      register_provider("foo")

      isolated_env = isolated_environment do |e|
        e.vagrantfile(<<-VF)
Vagrant.configure("2") do |config|
  config.vm.box = "foo"

  config.vm.provider :foo do |_, c|
    c.vm.box = "bar"
  end
end
VF
      end

      env = isolated_env.create_vagrant_env
      foo_vm = env.machine(:default, :foo)
      bar_vm = env.machine(:default, :bar)
      expect(foo_vm.config.vm.box).to eq("bar")
      expect(bar_vm.config.vm.box).to eq("foo")
    end

    it "should reload the cache if refresh is set" do
      # Create a provider
      foo_provider = register_provider("foo")

      # Create the configuration
      isolated_env = isolated_environment do |e|
        e.vagrantfile(<<-VF)
Vagrant.configure("2") do |config|
  config.vm.box = "base"
end
VF

        e.box3("base", "1.0", :foo)
      end

      env = isolated_env.create_vagrant_env
      vm1 = env.machine(:default, :foo)
      vm2 = env.machine(:default, :foo, true)
      vm3 = env.machine(:default, :foo)

      expect(vm1).not_to eql(vm2)
      expect(vm2).to eql(vm3)
    end

    it "should raise an error if the VM is not found" do
      expect { instance.machine("i-definitely-dont-exist", :virtualbox) }.
        to raise_error(Vagrant::Errors::MachineNotFound)
    end

    it "should raise an error if the provider is not found" do
      expect { instance.machine(:default, :lol_no) }.
        to raise_error(Vagrant::Errors::ProviderNotFound)
    end
  end

  describe "#machine_index" do
    it "returns a machine index" do
      expect(subject.machine_index).to be_kind_of(Vagrant::MachineIndex)
    end

    it "caches the result" do
      result = subject.machine_index
      expect(subject.machine_index).to equal(result)
    end

    it "uses a directory within the home directory by default" do
      klass = double("machine_index")
      stub_const("Vagrant::MachineIndex", klass)

      expect(klass).to receive(:new).with(any_args) do |path|
        expect(path.to_s.start_with?(subject.home_path.to_s)).to be(true)
        true
      end

      subject.machine_index
    end
  end

  describe "active machines" do
    it "should be empty if there is no root path" do
      Dir.mktmpdir("vagrant-test-env-no-root-path") do |temp_dir|
        instance = described_class.new(cwd: temp_dir)
        expect(instance.active_machines).to be_empty
      end
    end

    it "should be empty if the machines folder doesn't exist" do
      folder = instance.local_data_path.join("machines")
      expect(folder).not_to be_exist

      expect(instance.active_machines).to be_empty
    end

    it "should return the name and provider of active machines" do
      machines = instance.local_data_path.join("machines")

      # Valid machine, with "foo" and virtualbox
      machine_foo = machines.join("foo/virtualbox")
      machine_foo.mkpath
      machine_foo.join("id").open("w+") { |f| f.write("") }

      # Invalid machine (no ID)
      machine_bar = machines.join("bar/virtualbox")
      machine_bar.mkpath

      expect(instance.active_machines).to eq([[:foo, :virtualbox]])
    end
  end

  describe "batching" do
    let(:batch) do
      double("batch") do |b|
        allow(b).to receive(:run)
      end
    end

    context "without the disabling env var" do
      it "should run without disabling parallelization" do
        with_temp_env("VAGRANT_NO_PARALLEL" => nil) do
          expect(Vagrant::BatchAction).to receive(:new).with(true).and_return(batch)
          expect(batch).to receive(:run)

          instance.batch {}
        end
      end

      it "should run with disabling parallelization if explicit" do
        with_temp_env("VAGRANT_NO_PARALLEL" => nil) do
          expect(Vagrant::BatchAction).to receive(:new).with(false).and_return(batch)
          expect(batch).to receive(:run)

          instance.batch(false) {}
        end
      end
    end

    context "with the disabling env var" do
      it "should run with disabling parallelization" do
        with_temp_env("VAGRANT_NO_PARALLEL" => "yes") do
          expect(Vagrant::BatchAction).to receive(:new).with(false).and_return(batch)
          expect(batch).to receive(:run)

          instance.batch {}
        end
      end
    end
  end

  describe "current working directory" do
    it "is the cwd by default" do
      Dir.mktmpdir("vagrant-test-env-cwd-default") do |temp_dir|
        Dir.chdir(temp_dir) do
          with_temp_env("VAGRANT_CWD" => nil) do
            expect(described_class.new.cwd).to eq(Pathname.new(Dir.pwd))
          end
        end
      end
    end

    it "is set to the cwd given" do
      Dir.mktmpdir("vagrant-test-env-set-cwd") do |directory|
        instance = described_class.new(cwd: directory)
        expect(instance.cwd).to eq(Pathname.new(directory))
      end
    end

    it "is set to the environmental variable VAGRANT_CWD" do
      Dir.mktmpdir("vagrant-test-env-set-vagrant-cwd") do |directory|
        instance = with_temp_env("VAGRANT_CWD" => directory) do
          described_class.new
        end

        expect(instance.cwd).to eq(Pathname.new(directory))
      end
    end

    it "raises an exception if the CWD doesn't exist" do
      expect { described_class.new(cwd: "doesntexist") }.
        to raise_error(Vagrant::Errors::EnvironmentNonExistentCWD)
    end
  end

  describe "default provider" do
    let(:plugin_providers) { {} }

    before do
      m = Vagrant.plugin("2").manager
      allow(m).to receive(:providers).and_return(plugin_providers)
      allow_any_instance_of(described_class).to receive(:process_configured_plugins)
    end

    it "is the highest matching usable provider" do
      plugin_providers[:foo] = [provider_usable_class(true), { priority: 5 }]
      plugin_providers[:bar] = [provider_usable_class(true), { priority: 7 }]
      plugin_providers[:baz] = [provider_usable_class(true), { priority: 2 }]
      plugin_providers[:boom] = [provider_usable_class(true), { priority: 3 }]

      with_temp_env("VAGRANT_DEFAULT_PROVIDER" => nil,
                    "VAGRANT_PREFERRED_PROVIDERS" => nil) do
        expect(subject.default_provider).to eq(:bar)
      end
    end

    it "is the highest matching usable provider that is defaultable" do
      plugin_providers[:foo] = [provider_usable_class(true), { priority: 5 }]
      plugin_providers[:bar] = [
        provider_usable_class(true), { defaultable: false, priority: 7 }]
      plugin_providers[:baz] = [provider_usable_class(true), { priority: 2 }]

      with_temp_env("VAGRANT_DEFAULT_PROVIDER" => nil,
                    "VAGRANT_PREFERRED_PROVIDERS" => nil) do
        expect(subject.default_provider).to eq(:foo)
      end
    end

    it "is the highest matching usable provider that isn't excluded" do
      plugin_providers[:foo] = [provider_usable_class(true), { priority: 5 }]
      plugin_providers[:bar] = [provider_usable_class(true), { priority: 7 }]
      plugin_providers[:baz] = [provider_usable_class(true), { priority: 2 }]
      plugin_providers[:boom] = [provider_usable_class(true), { priority: 3 }]

      with_temp_env("VAGRANT_DEFAULT_PROVIDER" => nil,
                    "VAGRANT_PREFERRED_PROVIDERS" => nil) do
        expect(subject.default_provider(exclude: [:bar, :foo])).to eq(:boom)
      end
    end

    it "is the default provider set if usable" do
      plugin_providers[:foo] = [provider_usable_class(true), { priority: 5 }]
      plugin_providers[:bar] = [provider_usable_class(true), { priority: 7 }]
      plugin_providers[:baz] = [provider_usable_class(true), { priority: 2 }]
      plugin_providers[:boom] = [provider_usable_class(true), { priority: 3 }]

      with_temp_env("VAGRANT_DEFAULT_PROVIDER" => "baz",
                    "VAGRANT_PREFERRED_PROVIDERS" => nil) do
        expect(subject.default_provider).to eq(:baz)
      end
    end

    it "is the default provider set even if unusable" do
      plugin_providers[:baz] = [provider_usable_class(false), { priority: 5 }]
      plugin_providers[:foo] = [provider_usable_class(true), { priority: 5 }]
      plugin_providers[:bar] = [provider_usable_class(true), { priority: 7 }]

      with_temp_env("VAGRANT_DEFAULT_PROVIDER" => "baz",
                    "VAGRANT_PREFERRED_PROVIDERS" => nil) do
        expect(subject.default_provider).to eq(:baz)
      end
    end

    it "is the usable despite default if not forced" do
      plugin_providers[:baz] = [provider_usable_class(false), { priority: 5 }]
      plugin_providers[:foo] = [provider_usable_class(true), { priority: 5 }]
      plugin_providers[:bar] = [provider_usable_class(true), { priority: 7 }]

      with_temp_env("VAGRANT_DEFAULT_PROVIDER" => "baz",
                    "VAGRANT_PREFERRED_PROVIDERS" => nil) do
        expect(subject.default_provider(force_default: false)).to eq(:bar)
      end
    end

    it "prefers the default even if not forced" do
      plugin_providers[:baz] = [provider_usable_class(true), { priority: 5 }]
      plugin_providers[:foo] = [provider_usable_class(true), { priority: 5 }]
      plugin_providers[:bar] = [provider_usable_class(true), { priority: 7 }]

      with_temp_env("VAGRANT_DEFAULT_PROVIDER" => "baz",
                    "VAGRANT_PREFERRED_PROVIDERS" => nil) do
        expect(subject.default_provider(force_default: false)).to eq(:baz)
      end
    end

    it "uses the first usable provider that isn't the default if excluded" do
      plugin_providers[:foo] = [provider_usable_class(true), { priority: 5 }]
      plugin_providers[:bar] = [provider_usable_class(true), { priority: 7 }]
      plugin_providers[:baz] = [provider_usable_class(true), { priority: 8 }]

      with_temp_env("VAGRANT_DEFAULT_PROVIDER" => "baz",
                    "VAGRANT_PREFERRED_PROVIDERS" => nil) do
        expect(subject.default_provider(
          exclude: [:baz], force_default: false)).to eq(:bar)
      end
    end

    it "raise an error if nothing else is usable" do
      plugin_providers[:foo] = [provider_usable_class(false), { priority: 5 }]
      plugin_providers[:bar] = [provider_usable_class(false), { priority: 5 }]
      plugin_providers[:baz] = [provider_usable_class(false), { priority: 5 }]

      with_temp_env("VAGRANT_DEFAULT_PROVIDER" => nil,
                    "VAGRANT_PREFERRED_PROVIDERS" => nil) do
        expect { subject.default_provider }.to raise_error(
          Vagrant::Errors::NoDefaultProvider)
      end
    end

    it "is the provider in the Vagrantfile that is preferred and usable" do
      subject.vagrantfile.config.vm.provider "foo"
      subject.vagrantfile.config.vm.provider "bar"
      subject.vagrantfile.config.vm.finalize!

      plugin_providers[:foo] = [provider_usable_class(true), { priority: 5 }]
      plugin_providers[:bar] = [provider_usable_class(true), { priority: 7 }]
      plugin_providers[:baz] = [provider_usable_class(true), { priority: 2 }]
      plugin_providers[:boom] = [provider_usable_class(true), { priority: 3 }]

      with_temp_env("VAGRANT_DEFAULT_PROVIDER" => nil,
                    "VAGRANT_PREFERRED_PROVIDERS" => 'baz,bar') do
        expect(subject.default_provider).to eq(:bar)
      end
    end

    it "is the provider in the Vagrantfile that is usable" do
      subject.vagrantfile.config.vm.provider "foo"
      subject.vagrantfile.config.vm.provider "bar"
      subject.vagrantfile.config.vm.finalize!

      plugin_providers[:foo] = [provider_usable_class(true), { priority: 5 }]
      plugin_providers[:bar] = [provider_usable_class(true), { priority: 7 }]
      plugin_providers[:baz] = [provider_usable_class(true), { priority: 2 }]
      plugin_providers[:boom] = [provider_usable_class(true), { priority: 3 }]

      with_temp_env("VAGRANT_DEFAULT_PROVIDER" => nil,
                    "VAGRANT_PREFERRED_PROVIDERS" => nil) do
        expect(subject.default_provider).to eq(:foo)
      end
    end

    it "is the provider in the Vagrantfile that is usable even if only one specified (1)" do
      subject.vagrantfile.config.vm.provider "foo"
      subject.vagrantfile.config.vm.finalize!

      plugin_providers[:foo] = [provider_usable_class(true), { priority: 5 }]
      plugin_providers[:bar] = [provider_usable_class(true), { priority: 7 }]

      with_temp_env("VAGRANT_DEFAULT_PROVIDER" => nil,
                    "VAGRANT_PREFERRED_PROVIDERS" => nil) do
        expect(subject.default_provider).to eq(:foo)
      end
    end

    it "is the provider in the Vagrantfile that is usable even if only one specified (2)" do
      subject.vagrantfile.config.vm.provider "bar"
      subject.vagrantfile.config.vm.finalize!

      plugin_providers[:foo] = [provider_usable_class(true), { priority: 7 }]
      plugin_providers[:bar] = [provider_usable_class(true), { priority: 5 }]

      with_temp_env("VAGRANT_DEFAULT_PROVIDER" => nil,
                    "VAGRANT_PREFERRED_PROVIDERS" => nil) do
        expect(subject.default_provider).to eq(:bar)
      end
    end

    it "is the preferred usable provider outside the Vagrantfile" do
      subject.vagrantfile.config.vm.provider "foo"
      subject.vagrantfile.config.vm.finalize!

      plugin_providers[:foo] = [provider_usable_class(false), { priority: 5 }]
      plugin_providers[:bar] = [provider_usable_class(true), { priority: 7 }]
      plugin_providers[:baz] = [provider_usable_class(true), { priority: 2 }]
      plugin_providers[:boom] = [provider_usable_class(true), { priority: 3 }]

      with_temp_env("VAGRANT_DEFAULT_PROVIDER" => nil,
                    "VAGRANT_PREFERRED_PROVIDERS" => 'boom,baz') do
        expect(subject.default_provider).to eq(:boom)
      end
    end

    it "is the highest usable provider outside the Vagrantfile" do
      subject.vagrantfile.config.vm.provider "foo"
      subject.vagrantfile.config.vm.finalize!

      plugin_providers[:foo] = [provider_usable_class(false), { priority: 5 }]
      plugin_providers[:bar] = [provider_usable_class(true), { priority: 7 }]
      plugin_providers[:baz] = [provider_usable_class(true), { priority: 2 }]
      plugin_providers[:boom] = [provider_usable_class(true), { priority: 3 }]

      with_temp_env("VAGRANT_DEFAULT_PROVIDER" => nil,
                    "VAGRANT_PREFERRED_PROVIDERS" => nil) do
        expect(subject.default_provider).to eq(:bar)
      end
    end

    it "is the provider in the Vagrantfile that is usable for a machine" do
      subject.vagrantfile.config.vm.provider "foo"
      subject.vagrantfile.config.vm.define "sub" do |v|
        v.vm.provider "bar"
      end
      subject.vagrantfile.config.vm.finalize!

      plugin_providers[:foo] = [provider_usable_class(true), { priority: 5 }]
      plugin_providers[:bar] = [provider_usable_class(true), { priority: 7 }]
      plugin_providers[:baz] = [provider_usable_class(true), { priority: 2 }]
      plugin_providers[:boom] = [provider_usable_class(true), { priority: 3 }]

      with_temp_env("VAGRANT_DEFAULT_PROVIDER" => nil,
                    "VAGRANT_PREFERRED_PROVIDERS" => nil) do
        expect(subject.default_provider(machine: :sub)).to eq(:bar)
      end
    end
  end

  describe "local data path" do
    it "is set to the proper default" do
      default = instance.root_path.join(described_class::DEFAULT_LOCAL_DATA)
      expect(instance.local_data_path).to eq(default)
    end

    it "is expanded relative to the cwd" do
      Dir.mktmpdir("vagrant-test-env-relative-cwd") do |temp_dir|
        Dir.chdir(temp_dir) do
          instance = described_class.new(local_data_path: "foo")
          expect(instance.local_data_path).to eq(instance.cwd.join("foo"))
        end
      end
    end

    it "is set to the given value" do
      Dir.mktmpdir("vagrant-test-env-set-given") do |dir|
        instance = described_class.new(local_data_path: dir)
        expect(instance.local_data_path.to_s).to eq(dir)
      end
    end

    context "with environmental variable VAGRANT_DOTFILE_PATH set to the empty string" do
      it "is set to the default, from the work directory" do
        with_temp_env("VAGRANT_DOTFILE_PATH" => "") do
          instance = env.create_vagrant_env
          expect(instance.cwd).to eq(env.workdir)
          expect(instance.local_data_path.to_s).to eq(File.join(env.workdir, ".vagrant"))
        end
      end

      it "is set to the default, from a sub-directory of the work directory" do
        Dir.mktmpdir("sub-directory", env.workdir) do |temp_dir|
          with_temp_env("VAGRANT_DOTFILE_PATH" => "") do
            instance = env.create_vagrant_env(cwd: temp_dir)
            expect(instance.cwd.to_s).to eq(temp_dir)
            expect(instance.local_data_path.to_s).to eq(File.join(env.workdir, ".vagrant"))
          end
        end
      end
    end

    context "with environmental variable VAGRANT_DOTFILE_PATH set to an absolute path" do
      it "is set to VAGRANT_DOTFILE_PATH from the work directory" do
        Dir.mktmpdir("sub-directory", env.workdir) do |temp_dir|
          dotfile_path = File.join(temp_dir, ".vagrant-custom")

          with_temp_env("VAGRANT_DOTFILE_PATH" => dotfile_path) do
            instance = env.create_vagrant_env
            expect(instance.cwd).to eq(env.workdir)
            expect(instance.local_data_path.to_s).to eq(dotfile_path)
          end
        end
      end

      it "is set to VAGRANT_DOTFILE_PATH from a sub-directory of the work directory" do
        Dir.mktmpdir("sub-directory", env.workdir) do |temp_dir|
          dotfile_path = File.join(temp_dir, ".vagrant-custom")

          with_temp_env("VAGRANT_DOTFILE_PATH" => dotfile_path) do
            instance = env.create_vagrant_env(cwd: temp_dir)
            expect(instance.cwd.to_s).to eq(temp_dir)
            expect(instance.local_data_path.to_s).to eq(dotfile_path)
          end
        end
      end
    end

    context "with environmental variable VAGRANT_DOTFILE_PATH set to a relative path" do
      it "is set relative to the the work directory, from the work directory" do
        Dir.mktmpdir("sub-directory", env.workdir) do |temp_dir|
          with_temp_env("VAGRANT_DOTFILE_PATH" => ".vagrant-custom") do
            instance = env.create_vagrant_env
            expect(instance.cwd).to eq(env.workdir)
            expect(instance.local_data_path.to_s).to eq(File.join(env.workdir, ".vagrant-custom"))
          end
        end
      end

      it "is set relative to the the work directory, from a sub-directory of the work directory" do
        Dir.mktmpdir("sub-directory", env.workdir) do |temp_dir|
          with_temp_env("VAGRANT_DOTFILE_PATH" => ".vagrant-custom") do
            instance = env.create_vagrant_env(cwd: temp_dir)
            expect(instance.cwd.to_s).to eq(temp_dir)
            expect(instance.local_data_path.to_s).to eq(File.join(env.workdir, ".vagrant-custom"))
          end
        end
      end

      it "is set to the empty string when there is no valid work directory" do
        Dir.mktmpdir("out-of-tree-directory") do |temp_dir|
          with_temp_env("VAGRANT_DOTFILE_PATH" => ".vagrant-custom") do
            instance = env.create_vagrant_env(cwd: temp_dir)
            expect(instance.cwd.to_s).to eq(temp_dir)
            expect(instance.local_data_path.to_s).to eq("")
          end
        end
      end
    end

    context "with environmental variable VAGRANT_DOTFILE_PATH set with tilde" do
      it "is set relative to the user's home directory" do
        with_temp_env("VAGRANT_DOTFILE_PATH" => "~/.vagrant") do
          instance = env.create_vagrant_env
          expect(instance.cwd).to eq(env.workdir)
          expect(instance.local_data_path.to_s).to eq(File.join(Dir.home, ".vagrant"))
        end
      end
    end

    describe "upgrading V1 dotfiles" do
      let(:v1_dotfile_tempfile) do
        Tempfile.new("vagrant-upgrade-dotfile").tap do |f|
          f.close
        end
      end

      let(:v1_dotfile)          { Pathname.new(v1_dotfile_tempfile.path) }
      let(:local_data_path)     { v1_dotfile_tempfile.path }
      let(:instance) { described_class.new(local_data_path: local_data_path) }

      after do
        FileUtils.rm_rf(local_data_path)
      end

      it "should be fine if dotfile is empty" do
        v1_dotfile.open("w+") do |f|
          f.write("")
        end

        expect { instance }.to_not raise_error
      end

      it "should upgrade all active VMs" do
        active_vms = {
          "foo" => "foo_id",
          "bar" => "bar_id"
        }

        v1_dotfile.open("w+") do |f|
          f.write(JSON.dump({
            "active" => active_vms
          }))
        end

        expect { instance }.to_not raise_error

        local_data_pathname = Pathname.new(local_data_path)
        foo_id_file = local_data_pathname.join("machines/foo/virtualbox/id")
        expect(foo_id_file).to be_file
        expect(foo_id_file.read).to eq("foo_id")

        bar_id_file = local_data_pathname.join("machines/bar/virtualbox/id")
        expect(bar_id_file).to be_file
        expect(bar_id_file.read).to eq("bar_id")
      end

      it "should raise an error if invalid JSON" do
        v1_dotfile.open("w+") do |f|
          f.write("bad")
        end

        expect { instance }.
          to raise_error(Vagrant::Errors::DotfileUpgradeJSONError)
      end
    end
  end

  describe "copying the private SSH key" do
    it "copies the SSH key into the home directory" do
      env = isolated_environment
      instance = described_class.new(home_path: env.homedir)

      pk = env.homedir.join("insecure_private_key")
      expect(pk).to be_exist

      if !Vagrant::Util::Platform.windows?
        expect(Vagrant::Util::FileMode.from_octal(pk.stat.mode)).to be >= "600"
      end
    end
  end

  it "has a box collection pointed to the proper directory" do
    collection = instance.boxes
    expect(collection).to be_kind_of(Vagrant::BoxCollection)
    expect(collection.directory).to eq(instance.boxes_path)

    # Reach into some internal state here but not sure how else
    # to test this at the moment.
    expect(collection.instance_variable_get(:@hook)).
      to eq(instance.method(:hook))
  end

  describe "action runner" do
    it "has an action runner" do
      expect(instance.action_runner).to be_kind_of(Vagrant::Action::Runner)
    end

    it "has a `ui` in the globals" do
      result = nil
      callable = lambda { |env| result = env[:ui] }

      instance.action_runner.run(callable)
      expect(result).to eql(instance.ui)
    end
  end

  describe "#pushes" do
    it "returns the pushes from the Vagrantfile config" do
      environment = isolated_environment do |env|
        env.vagrantfile(<<-VF.gsub(/^ {10}/, ''))
          Vagrant.configure("2") do |config|
            config.push.define "noop"
          end
        VF
      end

      env = environment.create_vagrant_env
      expect(env.pushes).to eq([:noop])
    end
  end

  describe "#push" do
    let(:push_class) do
      Class.new(Vagrant.plugin("2", :push)) do
        def self.pushed?
          !!class_variable_get(:@@pushed)
        end

        def push
          self.class.class_variable_set(:@@pushed, true)
        end
      end
    end

    it "raises an exception when the push does not exist" do
      expect { instance.push("lolwatbacon") }
        .to raise_error(Vagrant::Errors::PushStrategyNotDefined)
    end

    it "raises an exception if the strategy does not exist" do
      environment = isolated_environment do |env|
        env.vagrantfile(<<-VF.gsub(/^ {10}/, ''))
          Vagrant.configure("2") do |config|
            config.push.define "lolwatbacon"
          end
        VF
      end

      env = environment.create_vagrant_env
      expect { env.push("lolwatbacon") }
        .to raise_error(Vagrant::Errors::PushStrategyNotLoaded)
    end

    it "executes the push action" do
      register_plugin("2") do |plugin|
        plugin.name "foo"

        plugin.push(:foo) do
          push_class
        end
      end

      environment = isolated_environment do |env|
        env.vagrantfile(<<-VF.gsub(/^ {10}/, ''))
          Vagrant.configure("2") do |config|
            config.push.define "foo"
          end
        VF
      end

      env = environment.create_vagrant_env
      env.push("foo")
      expect(push_class.pushed?).to be(true)
    end
  end

  describe "#hook" do
    it "should call the action runner with the proper hook" do
      hook_name = :foo

      expect(instance.action_runner).to receive(:run).with(any_args) { |callable, env|
        expect(env[:action_name]).to eq(hook_name)
      }

      instance.hook(hook_name)
    end

    it "should return the result of the action runner run" do
      expect(instance.action_runner).to receive(:run).and_return(:foo)

      expect(instance.hook(:bar)).to eq(:foo)
    end

    it "should allow passing in a custom action runner" do
      expect(instance.action_runner).not_to receive(:run)
      other_runner = double("runner")
      expect(other_runner).to receive(:run).and_return(:foo)

      expect(instance.hook(:bar, runner: other_runner)).to eq(:foo)
    end

    it "should allow passing in custom data" do
      expect(instance.action_runner).to receive(:run).with(any_args) { |callable, env|
        expect(env[:foo]).to eq(:bar)
      }

      instance.hook(:foo, foo: :bar)
    end

    it "should allow passing a custom callable" do
      expect(instance.action_runner).to receive(:run).with(any_args) { |callable, env|
        expect(callable).to eq(:what)
      }

      instance.hook(:foo, callable: :what)
    end
  end

  describe "primary machine name" do
    it "should be the only machine if not a multi-machine environment" do
      expect(instance.primary_machine_name).to eq(instance.machine_names.first)
    end

    it "should be the machine marked as the primary" do
      environment = isolated_environment do |env|
        env.vagrantfile(<<-VF)
Vagrant.configure("2") do |config|
  config.vm.box = "base"
  config.vm.define :foo
  config.vm.define :bar, primary: true
end
VF

        env.box3("base", "1.0", :virtualbox)
      end

      env = environment.create_vagrant_env
      expect(env.primary_machine_name).to eq(:bar)
    end

    it "should be nil if no primary is specified in a multi-machine environment" do
      environment = isolated_environment do |env|
        env.vagrantfile(<<-VF)
Vagrant.configure("2") do |config|
  config.vm.box = "base"
  config.vm.define :foo
  config.vm.define :bar
end
VF

        env.box3("base", "1.0", :virtualbox)
      end

      env = environment.create_vagrant_env
      expect(env.primary_machine_name).to be_nil
    end
  end

  describe "loading configuration" do
    it "should load global configuration" do
      environment = isolated_environment do |env|
        env.vagrantfile(<<-VF)
Vagrant.configure("2") do |config|
  config.ssh.port = 200
end
VF
      end

      env = environment.create_vagrant_env
      expect(env.vagrantfile.config.ssh.port).to eq(200)
    end

    it "should load from a custom Vagrantfile" do
      environment = isolated_environment do |env|
        env.file("non_standard_name", <<-VF)
Vagrant.configure("2") do |config|
  config.ssh.port = 200
end
VF
      end

      env = environment.create_vagrant_env(vagrantfile_name: "non_standard_name")
      expect(env.vagrantfile.config.ssh.port).to eq(200)
    end

    it "should load from a custom Vagrantfile specified by env var" do
      environment = isolated_environment do |env|
        env.file("some_other_name", <<-VF)
Vagrant.configure("2") do |config|
  config.ssh.port = 400
end
VF
      end

      env = with_temp_env("VAGRANT_VAGRANTFILE" => "some_other_name") do
        environment.create_vagrant_env
      end

      expect(env.vagrantfile.config.ssh.port).to eq(400)
    end
  end

  describe "ui" do
    it "should be a silent UI by default" do
      expect(described_class.new.ui).to be_kind_of(Vagrant::UI::Silent)
    end

    it "should be a UI given in the constructor" do
      # Create a custom UI for our test
      class CustomUI < Vagrant::UI::Interface; end

      instance = described_class.new(ui_class: CustomUI)
      expect(instance.ui).to be_kind_of(CustomUI)
    end
  end

  describe "#unload" do
    it "should run the unload hook" do
      expect(instance).to receive(:hook).with(:environment_unload).once
      instance.unload
    end
  end

  describe "getting machine names" do
    it "should return the default machine if no multi-VM is used" do
      # Create the config
      isolated_env = isolated_environment do |e|
        e.vagrantfile(<<-VF)
Vagrant.configure("2") do |config|
end
VF
      end

      env = isolated_env.create_vagrant_env
      expect(env.machine_names).to eq([:default])
    end

    it "should return the machine names in order" do
      # Create the config
      isolated_env = isolated_environment do |e|
        e.vagrantfile(<<-VF)
Vagrant.configure("2") do |config|
  config.vm.define "foo"
  config.vm.define "bar"
end
VF
      end

      env = isolated_env.create_vagrant_env
      expect(env.machine_names).to eq([:foo, :bar])
    end
  end

  describe "guess_provider" do
    before { allow_any_instance_of(described_class).to receive(:process_configured_plugins) }

    it "should return the default provider by default" do
      expect(subject).to receive(:default_provider).and_return("default_provider")
      expect(subject.send(:guess_provider)).to eq("default_provider")
    end

    context "when provider is defined via command line argument" do
      before { stub_const("ARGV", argv) }

      context "when provider is given as single argument" do
        let(:argv) { ["--provider=single_arg"] }

        it "should return the provider name" do
          expect(subject.send(:guess_provider)).to eq(:single_arg)
        end
      end

      context "when provider is given as two arguments" do
        let(:argv) { ["--provider", "double_arg"] }

        it "should return the provider name" do
          expect(subject.send(:guess_provider)).to eq(:double_arg)
        end
      end
    end

    context "when no default provider is available" do
      before {
        expect(subject).to receive(:default_provider).
          and_raise(Vagrant::Errors::NoDefaultProvider) }

      it "should return a nil value" do
        expect(subject.send(:guess_provider)).to be_nil
      end
    end
  end

  describe "#find_configured_plugins" do
    before do
      allow_any_instance_of(described_class).to receive(:guess_provider).and_return(:dummy)
      allow_any_instance_of(described_class).to receive(:process_configured_plugins)
    end

    it "should find no plugins when no plugins are configured" do
      expect(subject.send(:find_configured_plugins)).to be_empty
    end

    context "when plugins are defined in the Vagrantfile" do
      before do
        env.vagrantfile <<-VF
          Vagrant.configure("2") do |config|
            config.vagrant.plugins = "vagrant-plugin"
          end
          VF
      end

      it "should return the vagrant-plugin" do
        expect(subject.send(:find_configured_plugins).keys).to include("vagrant-plugin")
      end
    end

    context "when plugins are defined in the Vagrantfile of a box" do
      before do
        env.box3("foo", "1.0", :dummy, vagrantfile: <<-VF)
          Vagrant.configure("2") do |config|
            config.vagrant.plugins = "vagrant-plugin"
          end
        VF
        env.vagrantfile <<-VF
          Vagrant.configure("2") do |config|
            config.vm.box = "foo"
          end
        VF
      end

      it "should return the vagrant-plugin" do
        expect(subject.send(:find_configured_plugins).keys).to include("vagrant-plugin")
      end
    end

    context "when the box does not match the provider" do
      before do
        env.box3("foo", "1.0", :other, vagrantfile: <<-VF)
          Vagrant.configure("2") do |config|
            config.vagrant.plugins = "vagrant-plugin"
          end
        VF
        env.vagrantfile <<-VF
          Vagrant.configure("2") do |config|
            config.vm.box = "foo"
          end
        VF
      end

      it "should not return the vagrant-plugin" do
        expect(subject.send(:find_configured_plugins).keys).not_to include("vagrant-plugin")
      end
    end
  end

  describe "#process_configured_plugins" do
    let(:env) do
      isolated_environment.tap do |e|
        e.box3("base", "1.0", :virtualbox)
        e.vagrantfile(vagrantfile)
      end
    end

    let(:vagrantfile) do
      'Vagrant.configure("2"){ |config| config.vm.box = "base" }'
    end

    let(:plugin_manager) {
      double("plugin_manager", installed_plugins: installed_plugins, local_file: local_file)
    }

    let(:installed_plugins) { {} }
    let(:local_file) { double("local_file", installed_plugins: local_installed_plugins) }
    let(:local_installed_plugins) { {} }

    before do
      allow(Vagrant::Plugin::Manager).to receive(:instance).and_return(plugin_manager)
      allow(plugin_manager).to receive(:globalize!)
      allow(plugin_manager).to receive(:localize!)
      allow(plugin_manager).to receive(:load_plugins)
    end

    context "when local data directory does not exist" do
      let(:local_file) { nil }

      it "should properly return empty result" do
        expect(instance.send(:process_configured_plugins)).to be_empty
      end
    end

    context "plugins are disabled" do
      before{ allow(Vagrant).to receive(:plugins_enabled?).and_return(false) }

      it "should return empty result" do
        expect(instance.send(:process_configured_plugins)).to be_nil
      end
    end

    context "when vagrant is invalid" do
      let(:vagrantfile) { 'Vagrant.configure("2"){ |config| config.vagrant.bad_key = true }' }

      it "should raise a configuration error" do
        expect { instance.send(:process_configured_plugins) }.to raise_error(Vagrant::Errors::ConfigInvalid)
      end
    end

    context "with local plugins defined" do
      let(:vagrantfile) { 'Vagrant.configure("2"){ |config| config.vagrant.plugins = "vagrant" }' }
      let(:installed_plugins) { {"vagrant" => true} }

      context "with plugin already installed" do

        it "should not attempt to install a plugin" do
          expect(plugin_manager).not_to receive(:install_plugin)
          expect(instance.send(:process_configured_plugins)).to eq(local_installed_plugins)
        end
      end

      context "without plugin installed" do

        before { allow(instance).to receive(:exit) }

        it "should prompt user before installation" do
          expect(instance.ui).to receive(:ask).and_return("n")
          expect(plugin_manager).to receive(:installed_plugins).and_return({})
          expect { instance.send(:process_configured_plugins) }.to raise_error(Vagrant::Errors::PluginMissingLocalError)
        end

        it "should install plugin" do
          expect(instance.ui).to receive(:ask).and_return("y")
          expect(plugin_manager).to receive(:installed_plugins).and_return({})
          expect(plugin_manager).to receive(:install_plugin).and_return(double("spec", "name" => "vagrant", "version" => "1"))
          instance.send(:process_configured_plugins)
        end

        it "should exit after install" do
          expect(instance.ui).to receive(:ask).and_return("y")
          expect(plugin_manager).to receive(:installed_plugins).and_return({})
          expect(plugin_manager).to receive(:install_plugin).and_return(double("spec", "name" => "vagrant", "version" => "1"))
          expect(instance).to receive(:exit)
          instance.send(:process_configured_plugins)
        end
      end
    end
  end

  describe "#setup_local_data_path" do
    before do
      allow(FileUtils).to receive(:mkdir_p).and_call_original
      allow(FileUtils).to receive(:cp).and_call_original
    end

    it "should create an rgloader path" do
      expect(FileUtils).to receive(:mkdir_p).with(/(?!home)rgloader/)
      instance
    end

    it "should write the rgloader file" do
      expect(FileUtils).to receive(:cp).with(anything, /(?!home)rgloader.*rb$/)
      instance
    end
  end
end
