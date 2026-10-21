# Runtime checks for the rendered shell; requires Helm, Ruby and Minitest.
# Run: ruby charts/daytona-region/tests/runner_snapshot_route_test.rb
require 'yaml'
require 'json'
require 'open3'
require 'tmpdir'
require 'minitest/autorun'

class SnapshotRouteTest < Minitest::Test
  ROOT = File.expand_path('../../..', __dir__)
  FIXTURE = File.join(ROOT, 'charts/daytona-region/tests/fixtures/baseline.values.yaml')
  TARGET = 'ingress-nginx-controller.ingress-nginx.svc.cluster.local'

  def installer(extra = {})
    command = ['helm', 'template', 'test-release', File.join(ROOT, 'charts/daytona-region'),
               '-f', FIXTURE]
    {'services.runner.snapshotManagerInClusterRoute.enabled' => true}.merge(extra).each { |key, value| command.concat(['--set-json', "#{key}=#{JSON.generate(value)}"]) }
    output, error, status = Open3.capture3(*command)
    assert status.success?, error
    daemonset = YAML.load_stream(output).find { |document| document['kind'] == 'DaemonSet' }
    daemonset.dig('spec', 'template', 'spec', 'containers').find { |item| item['name'] == 'docker-installer' }['args'][0]
  end

  # Only run the alias setup portion. Host namespace access is replaced with a
  # test shell function that rewrites /etc/hosts references to a temporary file.
  # No bootstrap, Docker, Kubernetes or actual node operations are executed.
  def with_alias_shell(script, commands, initial_hosts: "127.0.0.1 localhost\n")
    Dir.mktmpdir('snapshot-route-test-') do |directory|
      File.write(File.join(directory, 'hosts'), initial_hosts)
      prefix = script.split('# Enter the host namespace and install Docker + Sysbox', 2).first
      shell = <<~'SH'
        getent() {
          printf '%s\n' "$*" >> "$TEST_DIR/queries"
          cat "$TEST_DIR/dns" 2>/dev/null || return 2
        }
        nsenter() {
          [ "$1 $2 $3 $4 $5 $6" = '-t 1 -m -u -n -i' ] || exit 97
          shift 6
          [ "$1 $2" = 'sh -c' ] || exit 98
          payload="$3"
          shift 3
          # The only rewrite is a constant file path inside known chart code.
          rewritten="$(printf '%s' "$payload" | sed "s|/etc/hosts|$TEST_DIR/hosts|g")"
          sh -c "$rewritten" "$@"
        }
      SH
      stdout, stderr, status = Open3.capture3({'TEST_DIR' => directory}, 'sh', stdin_data: shell + commands.fetch(:before, '') + prefix + commands.fetch(:after, ''))
      assert status.success?, "#{stdout}\n#{stderr}"
      yield directory, stdout, stderr
    end
  end

  def test_startup_refresh_service_change_and_failed_lookup
    script = installer
    assert_match(/while true; do\n\s+refresh_snapshot_manager_route\n/, script)
    with_alias_shell(script, {
      before: "printf '10.100.0.1 service\\n' > \"$TEST_DIR/dns\"\n",
      after: <<~'SH'
        cp "$TEST_DIR/hosts" "$TEST_DIR/startup"
        refresh_snapshot_manager_route
        cmp "$TEST_DIR/startup" "$TEST_DIR/hosts" || exit 10
        printf '10.100.0.2 service\n10.100.0.3 service\n' > "$TEST_DIR/dns"
        refresh_snapshot_manager_route
        cp "$TEST_DIR/hosts" "$TEST_DIR/updated"
        rm "$TEST_DIR/dns"
        refresh_snapshot_manager_route
        cmp "$TEST_DIR/updated" "$TEST_DIR/hosts" || exit 11
      SH
    }) do |directory, _stdout, stderr|
      assert_equal "127.0.0.1 localhost\n10.100.0.1 snapshots.daytona.example.com\n", File.read(File.join(directory, 'startup'))
      assert_equal "127.0.0.1 localhost\n10.100.0.2 snapshots.daytona.example.com\n", File.read(File.join(directory, 'hosts'))
      assert_equal ["hosts #{TARGET}"] * 4, File.readlines(File.join(directory, 'queries'), chomp: true)
      assert_includes stderr, 'WARN: could not resolve'
    end
  end

  def test_first_lookup_failure_leaves_hosts_untouched_and_recovers
    with_alias_shell(installer, {
      after: <<~'SH'
        cp "$TEST_DIR/hosts" "$TEST_DIR/failed"
        printf '10.100.0.4 service\n' > "$TEST_DIR/dns"
        refresh_snapshot_manager_route
      SH
    }) do |directory, _stdout, stderr|
      assert_equal "127.0.0.1 localhost\n", File.read(File.join(directory, 'failed'))
      assert_includes File.read(File.join(directory, 'hosts')), '10.100.0.4 snapshots.daytona.example.com'
      assert_includes stderr, 'WARN: could not resolve'
    end
  end

  def test_existing_static_alias_updates_without_losing_other_hosts
    initial = "127.0.0.1 localhost\n10.100.0.1 snapshots.daytona.example.com\n10.20.0.1 registry.example.com\n"
    with_alias_shell(installer, {before: "printf '10.100.0.5 service\\n' > \"$TEST_DIR/dns\"\n"}, initial_hosts: initial) do |directory, _stdout, _stderr|
      assert_equal initial.sub('10.100.0.1', '10.100.0.5'), File.read(File.join(directory, 'hosts'))
    end
  end

  def test_dynamic_alias_object_resolves_target_and_maps_hostname
    script = installer('services.runner.snapshotManagerInClusterRoute.enabled' => false,
                       'services.runner.dockerInstaller.dynamicHostAliases' => [{'hostname' => 'a.example.com', 'target' => 'svc.ns.svc.cluster.local'}])
    with_alias_shell(script, {before: "printf '10.100.0.6 service\\n' > \"$TEST_DIR/dns\"\n"}) do |directory, _stdout, _stderr|
      assert_equal "127.0.0.1 localhost\n10.100.0.6 a.example.com\n", File.read(File.join(directory, 'hosts'))
      assert_equal ['hosts svc.ns.svc.cluster.local'], File.readlines(File.join(directory, 'queries'), chomp: true)
    end
  end

  def test_dynamic_alias_object_failed_lookup_does_not_edit_hosts
    script = installer('services.runner.snapshotManagerInClusterRoute.enabled' => false,
                       'services.runner.dockerInstaller.dynamicHostAliases' => [{'hostname' => 'a.example.com', 'target' => 'svc.ns.svc.cluster.local'}])
    with_alias_shell(script, {}) do |directory, _stdout, stderr|
      assert_equal "127.0.0.1 localhost\n", File.read(File.join(directory, 'hosts'))
      assert_includes stderr, 'WARN: could not resolve svc.ns.svc.cluster.local'
    end
  end

  def test_rendered_shell_syntax
    script = installer('snapshotManagerUrl' => 'http://snapshots.example.com:5000/v2/',
                       'services.runner.dockerInstaller.dynamicHostAliases' => ['snapshot-manager', {'hostname' => 'a.example.com', 'target' => 'svc.ns.svc.cluster.local'}])
    _stdout, stderr, status = Open3.capture3('sh', '-n', stdin_data: script)
    assert status.success?, stderr
  end
end
