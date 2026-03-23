require 'spec_helper_acceptance'

describe 'basic installation' do
  before(:all) do
    on default, 'systemctl stop iop-*'
    on default, 'rm -rf /etc/containers/systemd/*'
    on default, 'systemctl daemon-reload'
    on default, 'podman rm --all --force'
    on default, 'podman secret rm --all'
    on default, 'podman network rm iop-core-network --force'
    on default, 'dnf -y remove postgres*'
    on default, 'dnf -y remove foreman*'
  end

  context 'with basic parameters' do
    it_behaves_like 'an idempotent resource' do
      let(:manifest) do
        <<-PUPPET
        class { 'iop::service_compliance': }
        PUPPET
      end
    end

    describe service('iop-service-compl-dbmigrate') do
      it { is_expected.to be_enabled }
    end

    describe service('iop-service-compl-service') do
      it { is_expected.to be_running }
      it { is_expected.to be_enabled }
    end

    describe service('iop-service-compl-ssg') do
      it { is_expected.to be_running }
      it { is_expected.to be_enabled }
    end

    describe service('iop-service-compl-sidekiq') do
      it { is_expected.to be_running }
      it { is_expected.to be_enabled }
    end

    describe service('iop-service-compl-inventory-consumer') do
      it { is_expected.to be_running }
      it { is_expected.to be_enabled }
    end

    describe service('iop-service-compl-import-ssg') do
      it { is_expected.not_to be_running }
    end

    describe command('systemctl is-enabled iop-service-compl-import-ssg') do
      its(:stdout) { should match /generated/ }
    end

    describe service('iop-service-compl-import-ssg.timer') do
      it { is_expected.to be_enabled }
      it { is_expected.to be_running }
    end

    describe file('/etc/systemd/system/iop-service-compl-import-ssg.timer') do
      it { is_expected.to be_file }
      its(:content) { should match /OnBootSec=5min/ }
      its(:content) { should match /OnUnitActiveSec=5min/ }
      its(:content) { should match /Persistent=true/ }
      its(:content) { should match /WantedBy=timers.target/ }
    end

    describe 'FDW setup verification' do
      describe command('sudo -u postgres psql compliance_db -c "SELECT * FROM pg_foreign_server WHERE srvname = \'hbi_server\';"') do
        its(:stdout) { should match /hbi_server/ }
        its(:exit_status) { should eq 0 }
      end

      describe command('sudo -u postgres psql compliance_db -c "SELECT * FROM information_schema.user_mappings WHERE foreign_server_name = \'hbi_server\';"') do
        its(:stdout) { should match /compliance_admin/ }
        its(:exit_status) { should eq 0 }
      end

      describe command('sudo -u postgres psql compliance_db -c "\\det inventory_source.*"') do
        its(:stdout) { should match /hosts/ }
        its(:exit_status) { should eq 0 }
      end

      describe command('sudo -u postgres psql compliance_db -c "\\dv inventory.*"') do
        its(:stdout) { should match /hosts/ }
        its(:exit_status) { should eq 0 }
      end

      describe command('sudo -u postgres psql compliance_db -c "SELECT 1 FROM inventory.hosts LIMIT 1;"') do
        its(:exit_status) { should eq 0 }
      end
    end
  end

  context 'with ensure => absent' do
    it_behaves_like 'an idempotent resource' do
      let(:manifest) do
        <<-PUPPET
        class { 'iop::service_compliance':
          ensure => 'absent',
        }
        PUPPET
      end
    end

    describe service('iop-service-compl-dbmigrate') do
      it { is_expected.not_to be_enabled }
    end

    describe service('iop-service-compl-service') do
      it { is_expected.not_to be_running }
      it { is_expected.not_to be_enabled }
    end

    describe service('iop-service-compl-ssg') do
      it { is_expected.not_to be_running }
      it { is_expected.not_to be_enabled }
    end

    describe service('iop-service-compl-sidekiq') do
      it { is_expected.not_to be_running }
      it { is_expected.not_to be_enabled }
    end

    describe service('iop-service-compl-inventory-consumer') do
      it { is_expected.not_to be_running }
      it { is_expected.not_to be_enabled }
    end

    describe service('iop-service-compl-import-ssg') do
      it { is_expected.not_to be_running }
      it { is_expected.not_to be_enabled }
    end

    describe service('iop-service-compl-import-ssg.timer') do
      it { is_expected.not_to be_running }
      it { is_expected.not_to be_enabled }
    end

    describe file('/etc/containers/systemd/iop-service-compl-dbmigrate.container') do
      it { is_expected.not_to exist }
    end

    describe file('/etc/containers/systemd/iop-service-compl-service.container') do
      it { is_expected.not_to exist }
    end

    describe file('/etc/containers/systemd/iop-service-compl-ssg.container') do
      it { is_expected.not_to exist }
    end

    describe file('/etc/containers/systemd/iop-service-compl-sidekiq.container') do
      it { is_expected.not_to exist }
    end

    describe file('/etc/containers/systemd/iop-service-compl-inventory-consumer.container') do
      it { is_expected.not_to exist }
    end

    describe file('/etc/containers/systemd/iop-service-compl-import-ssg.container') do
      it { is_expected.not_to exist }
    end

    describe file('/etc/systemd/system/iop-service-compl-import-ssg.timer') do
      it { is_expected.not_to exist }
    end

    describe command('podman secret ls --format "{{.Name}}" | grep "^iop-service-compliance-"') do
      its(:exit_status) { should eq 1 }
      its(:stdout) { should be_empty }
    end
  end
end
