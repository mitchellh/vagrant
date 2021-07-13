require_relative "../base"

require "vagrant/util/platform"

describe VagrantPlugins::ProviderVirtualBox::Action::PrepareNFSSettings do
  include_context "unit"
  include_context "virtualbox"

  let(:iso_env) do
    # We have to create a Vagrantfile so there is a root path
    env = isolated_environment
    env.vagrantfile("")
    env.create_vagrant_env
  end

  let(:machine) do
    iso_env.machine(iso_env.machine_names[0], :dummy).tap do |m|
      allow(m.provider).to receive(:driver).and_return(driver)
    end
  end

  let(:env)    {{ machine: machine }}
  let(:app)    { lambda { |*args| }}
  let(:driver) { double("driver") }
  let(:host)   { double("host") }

  subject { described_class.new(app, env) }

  before do
    env[:test] = true
    allow(machine.env).to receive(:host) { host }
    allow(host).to receive(:capability?).with(:nfs_installed) { true }
    allow(host).to receive(:capability).with(:nfs_installed) { true }
    # We don't care about smb support so return not installed
    allow(host).to receive(:capability?).with(:smb_installed).and_return(false)
  end

  it "calls the next action in the chain" do
    allow(driver).to receive(:read_network_interfaces).and_return({2 => {type: :hostonly, hostonly: "vmnet2"}})
    allow(driver).to receive(:read_host_only_interfaces).and_return([{name: "vmnet2", ip: "1.2.3.4"}])
    allow(driver).to receive(:read_guest_ip).with(1).and_return("2.3.4.5")

    called = false
    app = lambda { |*args| called = true }

    action = described_class.new(app, env)
    action.call(env)

    expect(called).to eq(true)
  end

  context "with an nfs synced folder" do
    let(:host_only_interfaces) {
      [{name: "vmnet2", ip: "1.2.3.4"}]
    }

    let(:guest_ip) {
      "2.3.4.5"
    }

    before do
      # We can't be on Windows, because NFS gets disabled on Windows
      allow(Vagrant::Util::Platform).to receive(:windows?).and_return(false)

      env[:machine].config.vm.synced_folder("/host/path", "/guest/path", type: "nfs")
      env[:machine].config.finalize!

      # Stub out the stuff so it just works by default
      allow(driver).to receive(:read_network_interfaces).and_return({
        2 => {type: :hostonly, hostonly: "vmnet2"},
      })
      allow(driver).to receive(:read_host_only_interfaces).and_return(host_only_interfaces)
      allow(driver).to receive(:read_guest_ip).with(1).and_return(guest_ip)

      # override sleep to 0 so test does not take seconds
      retry_options = subject.retry_options
      allow(subject).to receive(:retry_options).and_return(retry_options.merge(sleep: 0))
    end

    context "with ipv6 addresses" do
      let(:host_only_interfaces) {
        [{name: "vmnet2", ipv6: "fd63:acd4:5c42:0530::1"}]
      }

      let(:guest_ip) {
        "fd63:acd4:5c42:0530::2"
      }

      it "sets nfs_host_ip and nfs_machine_ip properly" do
        subject.call(env)

        expect(env[:nfs_host_ip]).to eq("fd63:acd4:5c42:0530::1")
        expect(env[:nfs_machine_ip]).to eq("fd63:acd4:5c42:0530::2")
      end
    end

    context "with host interface netmask defined" do
      context "with machine IP included within host interface range" do
        let(:host_only_interfaces) {
          [{name: "vmnet2", ip: "2.3.4.1", netmask: "255.255.255.0"}]
        }

        it "sets nfs_host_ip and nfs_machine_ip properly" do
          subject.call(env)

          expect(env[:nfs_host_ip]).to eq("2.3.4.1")
          expect(env[:nfs_machine_ip]).to eq("2.3.4.5")
        end
      end
      context "with machine IP included within host interface range" do
        let(:host_only_interfaces) {
          [{name: "vmnet2", ip: "1.2.3.4", netmask: "255.255.255.0"}]
        }

        it "raises an error when the machine IP is not within host interface range" do
          expect{ subject.call(env) }.to raise_error(Vagrant::Errors::NFSNoHostonlyNetwork)
        end
      end
    end

    it "sets nfs_host_ip and nfs_machine_ip properly" do
      subject.call(env)

      expect(env[:nfs_host_ip]).to    eq("1.2.3.4")
      expect(env[:nfs_machine_ip]).to eq("2.3.4.5")
    end

    it "raises an error when no host only adapter is configured" do
      allow(driver).to receive(:read_network_interfaces) {{}}

      expect { subject.call(env) }.
        to raise_error(Vagrant::Errors::NFSNoHostonlyNetwork)
    end

    it "retries through guest property not found errors" do
      raise_then_return = [
        lambda { raise Vagrant::Errors::VirtualBoxGuestPropertyNotFound, guest_property: 'stub' },
        lambda { "2.3.4.5" }
      ]
      allow(driver).to receive(:read_guest_ip) { raise_then_return.shift.call }

      subject.call(env)

      expect(env[:nfs_host_ip]).to    eq("1.2.3.4")
      expect(env[:nfs_machine_ip]).to eq("2.3.4.5")
    end

    it "raises an error informing the user of a bug when the guest IP cannot be found" do
      allow(driver).to receive(:read_guest_ip) {
        raise Vagrant::Errors::VirtualBoxGuestPropertyNotFound, guest_property: 'stub'
      }

      expect { subject.call(env) }.
        to raise_error(Vagrant::Errors::NFSNoGuestIP)
    end

    it "allows statically configured guest IPs to work for NFS, even when guest property would fail" do
      env[:machine].config.vm.network :private_network, ip: "11.12.13.14"

      allow(driver).to receive(:read_guest_ip) {
        raise Vagrant::Errors::VirtualBoxGuestPropertyNotFound, guest_property: "stub"
      }

      subject.call(env)

      expect(env[:nfs_host_ip]).to    eq("1.2.3.4")
      expect(env[:nfs_machine_ip]).to eq(["11.12.13.14"])
    end

    it "allows statically configured guest IPs to co-exist with dynamic host only IPs for NFS" do
      env[:machine].config.vm.network :private_network, ip: "11.12.13.14"

      subject.call(env)

      expect(env[:nfs_host_ip]).to    eq("1.2.3.4")
      expect(env[:nfs_machine_ip]).to eq(["11.12.13.14", "2.3.4.5"])
    end

    it "allows the use of scoped hash overrides as options" do
      env[:machine].config.vm.network :private_network, virtualbox__ip: "11.12.13.14"

      subject.call(env)

      expect(env[:nfs_host_ip]).to    eq("1.2.3.4")
      expect(env[:nfs_machine_ip]).to eq(["11.12.13.14", "2.3.4.5"])
    end
  end
end
