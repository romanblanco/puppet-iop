require 'spec_helper_acceptance'

describe 'compliance service installation' do
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

    describe service('iop-service-compliance-backend-api') do
      it { is_expected.to be_running }
      it { is_expected.to be_enabled }
    end

    describe service('iop-service-compliance-backend-consumer') do
      it { is_expected.to be_running }
      it { is_expected.to be_enabled }
    end

    describe service('iop-service-compliance-backend-sidekiq') do
      it { is_expected.to be_running }
      it { is_expected.to be_enabled }
    end

    describe service('iop-service-compliance-backend-ssg') do
      it { is_expected.to be_running }
      it { is_expected.to be_enabled }
    end

    describe 'FDW setup verification' do
      describe command('sudo -u postgres psql compliance_db -c "SELECT 1 FROM pg_foreign_server WHERE srvname = \'hbi_server\';"') do
        its(:stdout) { should match(/1/) }
        its(:exit_status) { should eq 0 }
      end

      describe command('sudo -u postgres psql compliance_db -c "\\det inventory_source.*"') do
        its(:stdout) { should match(/hosts/) }
        its(:exit_status) { should eq 0 }
      end

      describe command('sudo -u postgres psql compliance_db -c "\\dv inventory.*"') do
        its(:stdout) { should match(/hosts/) }
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

    describe service('iop-service-compliance-backend-api') do
      it { is_expected.not_to be_running }
      it { is_expected.not_to be_enabled }
    end

    describe service('iop-service-compliance-backend-consumer') do
      it { is_expected.not_to be_running }
      it { is_expected.not_to be_enabled }
    end

    describe service('iop-service-compliance-backend-sidekiq') do
      it { is_expected.not_to be_running }
      it { is_expected.not_to be_enabled }
    end

    describe service('iop-service-compliance-backend-ssg') do
      it { is_expected.not_to be_running }
      it { is_expected.not_to be_enabled }
    end
  end
end
