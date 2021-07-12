require File.expand_path("../../../../base", __FILE__)

require Vagrant.source_root.join("plugins/kernel_v2/config/vm")
require Vagrant.source_root.join("plugins/kernel_v2/config/ssh")


describe VagrantPlugins::Kernel_V2::VMConfig do
  include_context "unit"

  subject { described_class.new }

  let(:provider) { double("provider") }
  let(:machine) { double("machine", provider: provider, provider_name: "provider", name: "default") }

  def assert_invalid
    errors = subject.validate(machine)
    if !errors.values.any? { |v| !v.empty? }
      raise "No errors: #{errors.inspect}"
    end
  end

  def assert_valid
    errors = subject.validate(machine)
    if !errors.values.all? { |v| v.empty? }
      raise "Errors: #{errors.inspect}"
    end
  end

  def find_network(name)
    network_definitions = subject.networks.map do |n|
      n[1]
    end
    network_definitions.find {|n| n[:id] == name}
  end

  before do
    env = double("env")
    allow(env).to receive(:root_path).and_return(nil)
    allow(machine).to receive(:env).and_return(env)
    allow(machine).to receive(:provider_config).and_return(nil)
    allow(machine).to receive(:provider_options).and_return({})
    allow(machine).to receive_message_chain(:synced_folders, :types).and_return( {} )
    allow(provider).to receive(:capability?).with(:validate_disk_ext).and_return(true)
    allow(provider).to receive(:capability).with(:validate_disk_ext, "vdi").and_return(true)
    allow(provider).to receive(:capability?).with(:set_default_disk_ext).and_return(true)
    allow(provider).to receive(:capability).with(:set_default_disk_ext).and_return("vdi")

    subject.box = "foo"
  end

  it "is valid with test defaults" do
    subject.finalize!
    assert_valid
  end

  it "validates disables_host_modification option" do
    subject.allow_hosts_modification = true
    subject.finalize!
    assert_valid

    subject.allow_hosts_modification = false
    subject.finalize!
    assert_valid

    subject.allow_hosts_modification = "truthy"
    subject.finalize!
    assert_invalid
  end

  it "does not check for fstab caps if already set" do
    expect(machine).to_not receive(:synced_folder_types)
    subject.allow_fstab_modification = true
    subject.finalize!
    assert_valid
  end

  describe "#base_mac" do
    it "defaults properly" do
      subject.finalize!
      expect(subject.base_mac).to be_nil
    end
  end

  describe "#base_address" do
    it "defaults properly" do
      subject.finalize!
      expect(subject.base_address).to be_nil
    end
  end

  describe "#box" do
    it "is required" do
      subject.box = nil
      subject.finalize!
      assert_invalid
    end

    it "cannot be an empty string" do
      subject.box = ""
      subject.finalize!
      assert_invalid
    end

    it "is not required if the provider says so" do
      machine.provider_options[:box_optional] = true
      subject.box = nil
      subject.finalize!
      assert_valid
    end

    it "is invalid if clone is set" do
      subject.clone = "foo"
      subject.finalize!
      assert_invalid
    end
  end

  context "#box_check_update" do
    it "defaults to true" do
      with_temp_env("VAGRANT_BOX_UPDATE_CHECK_DISABLE" => "") do
        subject.finalize!
        expect(subject.box_check_update).to be(true)
      end
    end

    it "is false if VAGRANT_BOX_UPDATE_CHECK_DISABLE is set" do
      with_temp_env("VAGRANT_BOX_UPDATE_CHECK_DISABLE" => "1") do
        subject.finalize!
        expect(subject.box_check_update).to be(false)
      end
    end
  end

  describe "#box_url" do
    it "defaults to nil" do
      subject.finalize!

      expect(subject.box_url).to be_nil
    end

    it "turns into an array" do
      subject.box_url = "foo"
      subject.finalize!

      expect(subject.box_url).to eq(
        ["foo"])
    end

    it "keeps in array" do
      subject.box_url = ["foo", "bar"]
      subject.finalize!

      expect(subject.box_url).to eq(
        ["foo", "bar"])
    end
  end

  context "#box_version" do
    it "defaults to nil" do
      subject.finalize!

      expect(subject.box_version).to be_nil
    end

    it "errors if invalid version" do
      subject.box_version = "nope"
      subject.finalize!

      expect { assert_valid }.to raise_error(RuntimeError)
    end

    it "can have complex constraints" do
      subject.box_version = ">= 0, ~> 1.0"
      subject.finalize!

      assert_valid
    end

    ["1", 1, "1.0", 1.0].each do |valid|
      it "is valid: #{valid}" do
        subject.box_version = valid
        subject.finalize!
        assert_valid
      end
    end
  end

  describe "#communicator" do
    it "is nil by default" do
      subject.finalize!
      expect(subject.communicator).to be_nil
    end
  end

  describe "#guest" do
    it "is nil by default" do
      subject.finalize!
      expect(subject.guest).to be_nil
    end

    it "is symbolized" do
      subject.guest = "foo"
      subject.finalize!
      expect(subject.guest).to eq(:foo)
    end
  end

  describe "#hostname" do
    ["a", "foo", "foo-bar", "baz0"].each do |valid|
      it "is valid: #{valid}" do
        subject.hostname = valid
        subject.finalize!
        assert_valid
      end
    end
  end

  describe "#network(s)" do
    it "defaults to forwarding SSH by default" do
      subject.finalize!
      n = subject.networks
      expect(n.length).to eq(1)
      expect(n[0][0]).to eq(:forwarded_port)
      expect(n[0][1][:guest]).to eq(22)
      expect(n[0][1][:host]).to eq(2222)
      expect(n[0][1][:host_ip]).to eq("127.0.0.1")
      expect(n[0][1][:id]).to eq("ssh")
    end

    it "defaults to forwarding WinRM if communicator is winrm" do
      subject.communicator = "winrm"
      subject.finalize!
      n = subject.networks
      expect(n.length).to eq(3)

      expect(n[0][0]).to eq(:forwarded_port)
      expect(n[0][1][:guest]).to eq(5985)
      expect(n[0][1][:host]).to eq(55985)
      expect(n[0][1][:host_ip]).to eq("127.0.0.1")
      expect(n[0][1][:id]).to eq("winrm")

      expect(n[1][0]).to eq(:forwarded_port)
      expect(n[1][1][:guest]).to eq(5986)
      expect(n[1][1][:host]).to eq(55986)
      expect(n[1][1][:host_ip]).to eq("127.0.0.1")
      expect(n[1][1][:id]).to eq("winrm-ssl")
    end

    it "forwards ssh even if the communicator is winrm" do
      subject.communicator = "winrm"
      subject.finalize!
      n = subject.networks
      expect(n.length).to eq(3)

      expect(n[0][0]).to eq(:forwarded_port)
      expect(n[0][1][:guest]).to eq(5985)
      expect(n[0][1][:host]).to eq(55985)
      expect(n[0][1][:host_ip]).to eq("127.0.0.1")
      expect(n[0][1][:id]).to eq("winrm")

      expect(n[1][0]).to eq(:forwarded_port)
      expect(n[1][1][:guest]).to eq(5986)
      expect(n[1][1][:host]).to eq(55986)
      expect(n[1][1][:host_ip]).to eq("127.0.0.1")
      expect(n[1][1][:id]).to eq("winrm-ssl")

      expect(n[2][0]).to eq(:forwarded_port)
      expect(n[2][1][:guest]).to eq(22)
      expect(n[2][1][:host]).to eq(2222)
      expect(n[2][1][:host_ip]).to eq("127.0.0.1")
      expect(n[2][1][:id]).to eq("ssh")

    end

    it "allows overriding SSH" do
      subject.network "forwarded_port",
        guest: 22, host: 14100, id: "ssh"
      subject.finalize!

      n = subject.networks
      expect(n.length).to eq(1)
      expect(n[0][0]).to eq(:forwarded_port)
      expect(n[0][1][:guest]).to eq(22)
      expect(n[0][1][:host]).to eq(14100)
      expect(n[0][1][:id]).to eq("ssh")
    end

    it "allows overriding WinRM" do
      subject.communicator = :winrm
      subject.network "forwarded_port",
        guest: 5985, host: 14100, id: "winrm"
      subject.finalize!

      winrm_network = find_network 'winrm'
      expect(winrm_network[:guest]).to eq(5985)
      expect(winrm_network[:host]).to eq(14100)
      expect(winrm_network[:id]).to eq("winrm")
    end

    it "allows overriding WinRM SSL" do
      subject.communicator = :winrm
      subject.network "forwarded_port",
        guest: 5986, host: 14100, id: "winrm-ssl"
      subject.finalize!

      winrmssl_network = find_network 'winrm-ssl'
      expect(winrmssl_network[:guest]).to eq(5986)
      expect(winrmssl_network[:host]).to eq(14100)
      expect(winrmssl_network[:id]).to eq("winrm-ssl")
    end

    it "turns all forwarded port ports to ints" do
      subject.network "forwarded_port",
        guest: "45", host: "4545", id: "test"
      subject.finalize!
      n = subject.networks.find do |type, data|
        type == :forwarded_port && data[:id] == "test"
      end
      expect(n).to_not be_nil
      expect(n[1][:guest]).to eq(45)
      expect(n[1][:host]).to eq(4545)
    end

    it "is an error if forwarding a port too low" do
      subject.network "forwarded_port",
        guest: "45", host: "-5"
      subject.finalize!
      assert_invalid
    end

    it "is an error if forwarding a port too high" do
      subject.network "forwarded_port",
        guest: "45", host: "74545"
      subject.finalize!
      assert_invalid
    end

    it "is an error if multiple networks set hostname" do
      subject.network "public_network", ip: "192.168.0.1", hostname: true
      subject.network "public_network", ip: "192.168.0.2", hostname: true
      subject.finalize!
      assert_invalid
    end

    it "is an error if networks set hostname without ip" do
      subject.network "public_network", hostname: true
      subject.finalize!
      assert_invalid
    end

    it "is not an error if hostname non-bool" do
      subject.network "public_network",  ip: "192.168.0.1", hostname: "true"
      subject.finalize!
      assert_valid
    end

    it "is not an error if one hostname is true" do
      subject.network "public_network",  ip: "192.168.0.1", hostname: true
      subject.network "public_network",  ip: "192.168.0.2", hostname: false
      subject.finalize!
      assert_valid
    end
  end

  describe "#post_up_message" do
    it "defaults to empty string" do
      subject.finalize!
      expect(subject.post_up_message).to eq("")
    end

    it "can be set" do
      subject.post_up_message = "foo"
      subject.finalize!
      expect(subject.post_up_message).to eq("foo")
    end
  end

  describe "#provider and #__providers" do
    it "returns the providers in order" do
      subject.provider "foo"
      subject.provider "bar"
      subject.finalize!

      expect(subject.__providers).to eq([:foo, :bar])
    end

    describe "merging" do
      it "prioritizes new orders in later configs" do
        subject.provider "foo"

        other = described_class.new
        other.provider "bar"

        merged = subject.merge(other)

        expect(merged.__providers).to eq([:foo, :bar])
      end

      it "prioritizes duplicates in new orders in later configs" do
        subject.provider "foo"

        other = described_class.new
        other.provider "bar"
        other.provider "foo"

        merged = subject.merge(other)

        expect(merged.__providers).to eq([:foo, :bar])
      end
    end
  end

  describe "#provider and #get_provider_config" do
    it "compiles the configurations for a provider" do
      subject.provider "virtualbox" do |vb|
        vb.gui = true
      end

      subject.provider "virtualbox" do |vb|
        vb.name = "foo"
      end

      subject.finalize!

      config = subject.get_provider_config(:virtualbox)
      expect(config.name).to eq("foo")
      expect(config.gui).to be(true)
    end

    it "raises an exception if there is a problem loading" do
      subject.provider "virtualbox" do |vb|
        # Purposeful bad variable
        vm.foo = "bar"
      end

      expect { subject.finalize! }.
        to raise_error(Vagrant::Errors::VagrantfileLoadError)
    end

    it "ignores providers entirely if flag is provided" do
      subject.provider "virtualbox" do |vb|
        vb.nope = true
      end

      subject.provider "virtualbox" do |vb|
        vb.not_real = "foo"
      end

      subject.finalize!
      errors = subject.validate(machine, true)
      expect(errors).to eq({"vm"=>[]})
    end
  end

  describe "#provision" do
    it "stores the provisioners" do
      subject.provision("shell", inline: "foo")
      subject.provision("shell", inline: "bar", run: "always") { |s| s.path = "baz" }
      subject.provision("shell", inline: "foo", communicator_required: false)
      subject.finalize!

      r = subject.provisioners
      expect(r.length).to eql(3)
      expect(r[0].run).to be_nil
      expect(r[0].config.inline).to eql("foo")
      expect(r[1].config.inline).to eql("bar")
      expect(r[1].config.path).to eql("baz")
      expect(r[1].run).to eql(:always)
      expect(r[1].communicator_required).to eql(true)
      expect(r[2].communicator_required).to eql(false)
    end

    it "allows provisioner settings to be overridden" do
      subject.provision("s", path: "foo", type: "shell") { |s| s.inline = "foo" }
      subject.provision("s", inline: "bar", type: "shell") { |s| s.args = "bar" }
      subject.finalize!

      r = subject.provisioners
      expect(r.length).to eql(1)
      expect(r[0].config.args).to eql("bar")
      expect(r[0].config.inline).to eql("bar")
      expect(r[0].config.path).to eql("foo")
    end

    it "marks as invalid if a bad name" do
      subject.provision("nope", inline: "foo")
      subject.finalize!

      r = subject.provisioners
      expect(r.length).to eql(1)
      expect(r[0]).to be_invalid
    end

    it "allows provisioners that don't define any config" do
      register_plugin("2") do |p|
        p.name "foo"
        # This plugin registers a dummy provisioner
        # without registering a provisioner config
        p.provisioner(:foo) do
          Class.new Vagrant::plugin("2", :provisioner)
        end
      end

      subject.provision("foo") do |c|
        c.bar = "baz"
      end

      # This should succeed without errors
      expect{ subject.finalize! }.to_not raise_error
    end

    it "generates a uuid if no name was provided" do
      allow(SecureRandom).to receive(:uuid).and_return("MY_CUSTOM_VALUE")

      subject.provision("shell", path: "foo") { |s| s.inline = "foo" }
      subject.finalize!

      r = subject.provisioners
      expect(r[0].id).to eq("MY_CUSTOM_VALUE")
    end

    it "sets id as name if a name was provided" do
      subject.provision("ghost", type: "shell", path: "motoko") { |s| s.inline = "motoko" }
      subject.finalize!

      r = subject.provisioners
      expect(r[0].id).to eq(:ghost)
    end

    describe "merging" do
      it "ignores non-overriding runs" do
        subject.provision("shell", inline: "foo", run: "once")

        other = described_class.new
        other.provision("shell", inline: "bar", run: "always")

        merged = subject.merge(other)
        merged_provs = merged.provisioners

        expect(merged_provs.length).to eql(2)
        expect(merged_provs[0].run).to eq("once")
        expect(merged_provs[1].run).to eq("always")
      end

      it "does not merge duplicate provisioners" do
        subject.provision("shell", inline: "foo")
        subject.provision("shell", inline: "bar")

        merged = subject.merge(subject)
        merged_provs = merged.provisioners

        expect(merged_provs.length).to eql(2)
      end

      it "copies the configs" do
        subject.provision("shell", inline: "foo")
        subject_provs = subject.provisioners

        other = described_class.new
        other.provision("shell", inline: "bar")

        merged = subject.merge(other)
        merged_provs = merged.provisioners

        expect(merged_provs.length).to eql(2)
        expect(merged_provs[0].config.inline).
          to eq(subject_provs[0].config.inline)
        expect(merged_provs[0].config.object_id).
          to_not eq(subject_provs[0].config.object_id)
      end

      it "uses the proper order when merging overrides" do
        subject.provision("original", inline: "foo", type: "shell")
        subject.provision("other", inline: "other", type: "shell")

        other = described_class.new
        other.provision("shell", inline: "bar")
        other.provision("original", inline: "foo-overload", type: "shell")

        merged = subject.merge(other)
        merged_provs = merged.provisioners

        expect(merged_provs.length).to eql(3)
        expect(merged_provs[0].config.inline).
          to eq("other")
        expect(merged_provs[1].config.inline).
          to eq("bar")
        expect(merged_provs[2].config.inline).
          to eq("foo-overload")
      end

      it "can preserve order for overrides" do
        subject.provision("original", inline: "foo", type: "shell")
        subject.provision("other", inline: "other", type: "shell")

        other = described_class.new
        other.provision("shell", inline: "bar")
        other.provision(
          "original", inline: "foo-overload", type: "shell",
          preserve_order: true)

        merged = subject.merge(other)
        merged_provs = merged.provisioners

        expect(merged_provs.length).to eql(3)
        expect(merged_provs[0].config.inline).
          to eq("foo-overload")
        expect(merged_provs[1].config.inline).
          to eq("other")
        expect(merged_provs[2].config.inline).
          to eq("bar")
      end
    end
  end

  describe "#disk" do
    before(:each) do
      allow(Vagrant::Util::Experimental).to receive(:feature_enabled?).
        with("disks").and_return("true")
    end

    it "stores the disks" do
      subject.disk(:disk, size: 100, primary: true)
      subject.disk(:disk, size: 1000, name: "storage")
      subject.finalize!

      assert_valid

      d = subject.disks
      expect(d.length).to eql(2)
      expect(d[0].size).to eql(100)
      expect(d[1].size).to eql(1000)
      expect(d[1].name).to eql("storage")
    end

    it "raises an error with duplicate names" do
      subject.disk(:disk, size: 100, name: "foo")
      subject.disk(:disk, size: 1000, name: "foo", primary: false)
      subject.finalize!
      assert_invalid
    end

    it "raises an error with duplicate disk files" do
      allow(File).to receive(:file?).with("bar.vmdk").and_return(true)
      subject.disk(:disk, size: 100, name: "foo1", file: "bar.vmdk")
      subject.disk(:disk, size: 100, name: "foo2", file: "bar.vmdk")
      subject.finalize!
      assert_invalid
    end

    it "does not merge duplicate disks" do
      subject.disk(:disk, size: 1000, primary: false, name: "storage")
      subject.disk(:disk, size: 1000, primary: false, name: "backup")

      merged = subject.merge(subject)
      merged_disks = merged.disks

      expect(merged_disks.length).to eql(2)
    end

    it "ignores non-overriding runs" do
      subject.disk(:disk, name: "foo")

      other = described_class.new
      other.disk(:disk, name: "bar", primary: false)

      merged = subject.merge(other)
      merged_disks = merged.disks

      expect(merged_disks.length).to eql(2)
      expect(merged_disks[0].name).to eq("foo")
      expect(merged_disks[1].name).to eq("bar")
    end

    it "adds provider config with `__` config form" do
      subject.disk(:disk, size: 1000, primary: false, name: "storage",  provider__something: "special")
      expect(subject.disks[0].provider_config).to eq({:provider=>{:something=>"special"}})
    end

    it "adds provider config with Hash config form" do
      subject.disk(:disk, size: 1000, primary: false, name: "storage",  provider: {something: "special"})
      expect(subject.disks[0].provider_config).to eq({:provider=>{:something=>"special"}})
    end
  end

  describe "#synced_folder(s)" do
    it "defaults to sharing the current directory" do
      subject.finalize!
      sf = subject.synced_folders
      expect(sf.length).to eq(1)
      expect(sf).to have_key("/vagrant")
      expect(sf["/vagrant"][:disabled]).to_not be
    end

    it "allows overriding settings on the /vagrant sf" do
      subject.synced_folder(".", "/vagrant", disabled: true)
      subject.finalize!
      sf = subject.synced_folders
      expect(sf.length).to eq(1)
      expect(sf).to have_key("/vagrant")
      expect(sf["/vagrant"][:disabled]).to be(true)
    end

    it "allows overriding previously set options" do
      subject.synced_folder(".", "/vagrant", disabled: true)
      subject.synced_folder(".", "/vagrant", foo: :bar)
      subject.finalize!
      sf = subject.synced_folders
      expect(sf.length).to eq(1)
      expect(sf).to have_key("/vagrant")
      expect(sf["/vagrant"][:disabled]).to be(false)
      expect(sf["/vagrant"][:foo]).to eq(:bar)
    end

    # This is a little bit of a special case since nfs can be specified
    # as `type: "nfs"` or `nfs: true`
    it "properly overrides nfs" do
      subject.synced_folder(".", "/vagrant", nfs: true)
      subject.synced_folder(".", "/vagrant", type: "rsync")
      subject.finalize!
      sf = subject.synced_folders
      expect(sf.length).to eq(1)
      expect(sf).to have_key("/vagrant")
      expect(sf["/vagrant"][:type]).to be(:rsync)
      expect(sf["/vagrant"][:nfs]).to eq(nil)
    end

    it "is not an error if guest path is empty but name is not" do
      subject.synced_folder(".", "", name: "my-vagrant-folder")
      subject.finalize!
      assert_valid
    end

    it "allows providing custom name via options" do
      subject.synced_folder(".", "/vagrant", name: "my-vagrant-folder")
      sf = subject.synced_folders
      expect(sf).to have_key("my-vagrant-folder")
      expect(sf["my-vagrant-folder"][:guestpath]).to eq("/vagrant")
      expect(sf["my-vagrant-folder"][:hostpath]).to eq(".")
    end

    it "allows providing custom name without guest path" do
      subject.synced_folder(".", name: "my-vagrant-folder")
      sf = subject.synced_folders
      expect(sf).to have_key("my-vagrant-folder")
      expect(sf["my-vagrant-folder"][:hostpath]).to eq(".")
    end

    it "requires either guest path or name" do
      subject.synced_folder(".", name: nil, guestpath: nil)
      subject.finalize!
      assert_invalid
    end

    it "keeps nil guest path if not provided" do
      subject.synced_folder(".", name: "my-vagrant-folder")
      sf = subject.synced_folders
      expect(sf["my-vagrant-folder"][:guestpath]).to be_nil
    end

    context "WSL host paths" do
      let(:valid_path){ "/mnt/c/path" }
      let(:invalid_path){ "/home/vagrant/path" }
      let(:synced_folder_impl){ double("synced_folder_impl", new: double("synced_folder_inst", usable?: true, _initialize: true)) }
      let(:fs_config){ double("fs_config", vm: double("fs_vm", allowed_synced_folder_types: nil)) }
      let(:plugin){ double("plugin", manager: manager) }
      let(:manager){ double("manager", synced_folders: {sf_impl: [synced_folder_impl, 1]}) }

      let(:stub_pathname){ double("stub_pathname", directory?: true, relative?: false) }

      before do
        allow(Pathname).to receive(:new).and_return(stub_pathname)
        allow(stub_pathname).to receive(:expand_path).and_return(stub_pathname)
        allow(Vagrant::Util::Platform).to receive(:wsl?).and_return(true)
        allow(Vagrant::Util::Platform).to receive(:wsl_drvfs_path?).with(valid_path).and_return(true)
        allow(Vagrant::Util::Platform).to receive(:wsl_drvfs_path?).with(invalid_path).and_return(false)
        allow(machine).to receive(:config).and_return(fs_config)
        allow(Vagrant).to receive(:plugin).with("2").and_return(plugin)
        subject.synced_folder(".", "/vagrant", disabled: true)
      end

      it "is valid when located on DrvFs" do
        subject.synced_folder(valid_path, "/guest/path")
        subject.finalize!
        assert_valid
      end

      it "is invalid when not located on DrvFs" do
        subject.synced_folder(invalid_path, "/guest/path")
        subject.finalize!
        assert_invalid
      end

      context "when synced folder defines support for non-DrvFs" do
        let(:support_nondrvfs){ true }

        before do
          allow(synced_folder_impl).to receive(:respond_to?).with(:wsl_allow_non_drvfs?).and_return(true)
          allow(synced_folder_impl).to receive(:wsl_allow_non_drvfs?).and_return(support_nondrvfs)
        end

        context "and is supported" do
          it "is valid when located on DrvFs" do
            subject.synced_folder(valid_path, "/guest/path")
            subject.finalize!
            assert_valid
          end

          it "is valid when not located on DrvFs" do
            subject.synced_folder(invalid_path, "/guest/path")
            subject.finalize!
            assert_valid
          end
        end

        context "and is not supported" do
          let(:support_nondrvfs){ false }

          it "is valid when located on DrvFs" do
            subject.synced_folder(valid_path, "/guest/path")
            subject.finalize!
            assert_valid
          end

          it "is invalid when not located on DrvFs" do
            subject.synced_folder(invalid_path, "/guest/path")
            subject.finalize!
            assert_invalid
          end
        end
      end
    end
  end

  describe "#usable_port_range" do
    it "defaults properly" do
      subject.finalize!
      expect(subject.usable_port_range).to eq(
        Range.new(2200, 2250))
    end
  end

  describe "#communicator and #get_communicator" do
    it "#communicator is getter if name is nil" do
      subject.communicator = "bar"
      expect(subject.communicator).to eq(:bar)
    end

    it "#communicator return the last defined communicator" do
      subject.communicator 'foo'
      subject.communicator 'bar'
      expect(subject.communicator).to eq(:bar)
    end
  end

  describe "#communicator and #__communicators" do
    it "we can create block with #communicator" do
      subject.communicator 'foo'
      subject.communicator 'bar'
      subject.finalize!
      expect(subject.instance_variable_get(:@__communicators)).to eq({:foo => [], :bar => []})
    end
  end

  describe "#communicator and #get_communicator_config" do
    let(:ssh_klass) { VagrantPlugins::Kernel_V2::SSHConfig }
    let(:config) { double('config') }
    before do
      config.instance_variable_set(:@keys, {:ssh => ssh_klass.new })
      allow(machine).to receive(:config).and_return(config)
    end
    it "compiles the configurations for a communicator" do
      subject.communicator "ssh" do |ssh|
        ssh.compression = false
        ssh.password = "bar"
      end

      subject.communicator "ssh" do |ssh|
        ssh.username = "foo"
      end

      subject.finalize!

      config = subject.get_communicator_config(:ssh)
      expect(config.username).to eq("foo")
      expect(config.password).to eq("bar")
      expect(config.compression).to be(false)
    end

    it "compiles the configurations for two communicator" do
      subject.communicator "ssh" do |ssh|
        ssh.compression = false
        ssh.password = "bar"
      end

      subject.communicator "winssh" do |ssh|
        ssh.username = "foo"
        ssh.password = "foo"
      end

      subject.finalize!

      config = subject.get_communicator_config(:ssh)
      expect(config.password).to eq("bar")
      expect(config.compression).to be(false)
      config = subject.get_communicator_config(:winssh)
      expect(config.username).to eq("foo")
      expect(config.password).to eq("foo")
    end

    it "raises an exception if there is a problem loading" do
      subject.communicator "ssh" do |ssh|
        # Purposeful bad variable
        ss.foo = "bar"
      end

      expect { subject.finalize! }.
        to raise_error(Vagrant::Errors::VagrantfileLoadError)
    end

    it "ignores communicator entirely if communicator does not exist" do
      subject.communicator "foo" do |ssh|
      end

      subject.finalize!
      errors = subject.validate(machine, true)
      expect(errors).to eq({"vm"=>["The 'foo' communicator could not be found."]})
    end

    it "ignores communicator entirely if flag is provided" do
      subject.communicator "ssh" do |ssh|
        ssh.nope = true
      end

      subject.communicator "ssh" do |ssh|
        ssh.not_real = "foo"
      end

      subject.finalize!
      errors = subject.validate(machine, true)
      expect(errors).to eq({"SSH" => ["The following settings shouldn't exist: nope, not_real"], "vm"=>[]})
    end

    it "return nil if communicator name does not exist" do
      subject.finalize!

      config = subject.get_communicator_config(:foo)
      expect(config).to eq(nil)
    end

    it "overide existing config" do
      config_ssh = config.instance_variable_get(:@keys)[:ssh]
      config_ssh.connect_timeout = 2
      config_ssh.username = 'foo'
      subject.communicator "ssh" do |ssh|
        ssh.username = 'bar'
      end

      subject.finalize!
      config_ssh = subject.get_communicator_config(:ssh, config)
      expect(config_ssh.connect_timeout).to eq(2)
      expect(config_ssh.username).to eq('bar')
    end

    describe "merging" do
      it "prioritizes #__communicator, #__last_communicator_created and __communicators" do
        subject.communicator "foo"
        subject.communicator = "baz"

        other = described_class.new
        other.communicator "bar"

        merged = subject.merge(other)

        expect(merged.instance_variable_get(:@__communicators)).to eq({:foo => [], :bar => []})
        expect(merged.instance_variable_get(:@__last_communicator_created)).to eq(:bar)
        expect(merged.instance_variable_get(:@__communicator)).to eq(:baz)
      end

      it "prioritizes #__last_communicator_created" do
        subject.communicator "foo"

        other = described_class.new
        other.communicator = "bar"

        merged = subject.merge(other)

        expect(merged.instance_variable_get(:@__communicators)).to eq({:foo => []})
        expect(merged.instance_variable_get(:@__last_communicator_created)).to eq(:foo)
        expect(merged.instance_variable_get(:@__communicator)).to eq(:bar)
      end

      it "overides config" do
        subject.communicator "ssh" do |ssh|
          ssh.compression = false
          ssh.password = "bar"
        end

        subject.communicator "ssh" do |ssh|
          ssh.username = "foo"
          ssh.password = "foo"
        end

        subject.finalize!

        config = subject.get_communicator_config(:ssh)
        expect(config.compression).to be(false)
        expect(config.username).to eq("foo")
        expect(config.password).to eq("foo")
      end

    end

  end
end
