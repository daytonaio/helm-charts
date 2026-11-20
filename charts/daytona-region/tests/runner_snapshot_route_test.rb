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
        # Record the bound, then run the mocked command.
        timeout() {
          printf 'timeout %s ' "$1" >> "$TEST_DIR/queries"
          shift
          "$@"
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
      assert_equal ["timeout 5 hosts #{TARGET}"] * 4, File.readlines(File.join(directory, 'queries'), chomp: true)
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
      assert_equal "127.0.0.1 localhost\n10.20.0.1 registry.example.com\n10.100.0.5 snapshots.daytona.example.com\n", File.read(File.join(directory, 'hosts'))
    end
  end

  def test_repeated_refresh_with_same_ip_leaves_hosts_untouched
    with_alias_shell(installer, {
      before: "printf '10.100.0.1 service\\n' > \"$TEST_DIR/dns\"\n",
      after: <<~'SH'
        touch -t 200001010000 "$TEST_DIR/hosts"
        ls -i "$TEST_DIR/hosts" > "$TEST_DIR/inode.before"
        refresh_snapshot_manager_route
        refresh_snapshot_manager_route
        ls -i "$TEST_DIR/hosts" > "$TEST_DIR/inode.after"
      SH
    }) do |directory, stdout, _stderr|
      hosts = File.join(directory, 'hosts')
      assert_equal File.read(File.join(directory, 'inode.before')), File.read(File.join(directory, 'inode.after'))
      assert_equal 2000, File.mtime(hosts).year
      assert_equal 1, stdout.scan('[host-alias] set').size
      assert_empty Dir.glob("#{hosts}.*")
    end
  end

  def test_restart_with_several_aliases_leaves_hosts_untouched
    script = installer('services.runner.hostAliases' => [{'ip' => '10.0.0.5', 'hostnames' => ['a.example.com', 'b.example.com']}],
                       'services.runner.dockerInstaller.dynamicHostAliases' => ['snapshot-manager', {'hostname' => 'c.example.com', 'target' => 'svc.ns.svc.cluster.local'}])
    initial = "127.0.0.1 localhost\n10.0.0.5 a.example.com\n10.0.0.5 b.example.com\n10.100.0.1 snapshot-manager\n" \
              "10.100.0.1 c.example.com\n10.100.0.1 snapshots.daytona.example.com\n"
    with_alias_shell(script, {
      before: "printf '10.100.0.1 service\\n' > \"$TEST_DIR/dns\"\ntouch -t 200001010000 \"$TEST_DIR/hosts\"\n"
    }, initial_hosts: initial) do |directory, stdout, _stderr|
      hosts = File.join(directory, 'hosts')
      assert_equal initial, File.read(hosts)
      assert_equal 2000, File.mtime(hosts).year
      refute_includes stdout, '[host-alias] set'
    end
  end

  def test_current_entry_stays_in_place_and_stale_entries_are_removed
    initial = "127.0.0.1 localhost\n10.0.0.7 snapshots.daytona.example.com\n10.100.0.1 snapshots.daytona.example.com\n" \
              "10.0.0.9 other.example.com snapshots.daytona.example.com\n10.20.0.1 registry.example.com\n"
    with_alias_shell(installer, {before: "printf '10.100.0.1 service\\n' > \"$TEST_DIR/dns\"\n"}, initial_hosts: initial) do |directory, stdout, _stderr|
      assert_equal "127.0.0.1 localhost\n10.100.0.1 snapshots.daytona.example.com\n10.0.0.9 other.example.com\n10.20.0.1 registry.example.com\n",
                   File.read(File.join(directory, 'hosts'))
      assert_equal 1, stdout.scan('[host-alias] set').size
    end
  end

  def test_names_are_compared_as_strings
    script = installer('services.runner.snapshotManagerInClusterRoute.enabled' => false,
                       'services.runner.hostAliases' => [{'ip' => '10.1.1.1', 'hostnames' => ['100']}])
    initial = "127.0.0.1 localhost\n10.0.0.7 1e2 keep.example.com\n10.0.0.8 0100 100.0\n"
    with_alias_shell(script, {}, initial_hosts: initial) do |directory, _stdout, _stderr|
      assert_equal "#{initial}10.1.1.1 100\n", File.read(File.join(directory, 'hosts'))
    end
  end

  def test_stale_crlf_entry_is_removed
    initial = "127.0.0.1 localhost\r\n10.0.0.7 snapshots.daytona.example.com\r\n10.0.0.9 snapshots.daytona.example.com other.example.com\r\n"
    with_alias_shell(installer, {before: "printf '10.100.0.1 service\\n' > \"$TEST_DIR/dns\"\n"}, initial_hosts: initial) do |directory, _stdout, _stderr|
      assert_equal "127.0.0.1 localhost\r\n10.0.0.9 other.example.com\r\n10.100.0.1 snapshots.daytona.example.com\n",
                   File.read(File.join(directory, 'hosts'))
    end
  end

  def test_secondary_alias_is_removed_from_other_entries
    initial = "127.0.0.1 localhost\n10.0.0.9 other.example.com snapshots.daytona.example.com extra.example.com # keep\n"
    with_alias_shell(installer, {before: "printf '10.100.0.1 service\\n' > \"$TEST_DIR/dns\"\n"}, initial_hosts: initial) do |directory, _stdout, _stderr|
      assert_equal "127.0.0.1 localhost\n10.0.0.9 other.example.com extra.example.com # keep\n10.100.0.1 snapshots.daytona.example.com\n", File.read(File.join(directory, 'hosts'))
    end
  end

  def test_entries_naming_only_the_snapshot_host_are_replaced
    initial = "127.0.0.1 localhost\n10.0.0.8\tsnapshots.daytona.example.com\n10.20.0.1 registry.example.com\n10.0.0.7 snapshots.daytona.example.com # stale\n"
    with_alias_shell(installer, {before: "printf '10.100.0.1 service\\n' > \"$TEST_DIR/dns\"\n"}, initial_hosts: initial) do |directory, _stdout, _stderr|
      assert_equal "127.0.0.1 localhost\n10.20.0.1 registry.example.com\n10.100.0.1 snapshots.daytona.example.com\n", File.read(File.join(directory, 'hosts'))
    end
  end

  def test_comment_and_blank_lines_are_preserved
    initial = "# snapshots.daytona.example.com pinned by hand\n\n  # 10.0.0.7 snapshots.daytona.example.com\n127.0.0.1\tlocalhost # loopback\n"
    with_alias_shell(installer, {before: "printf '10.100.0.1 service\\n' > \"$TEST_DIR/dns\"\n"}, initial_hosts: initial) do |directory, _stdout, _stderr|
      assert_equal "#{initial}10.100.0.1 snapshots.daytona.example.com\n", File.read(File.join(directory, 'hosts'))
    end
  end

  def test_failed_write_warns_and_leaves_hosts_untouched
    skip 'root ignores directory permissions' if Process.uid.zero?
    with_alias_shell(installer, {
      before: "printf '10.100.0.1 service\\n' > \"$TEST_DIR/dns\"\n: > \"$TEST_DIR/queries\"\nchmod a-w \"$TEST_DIR\"\n",
      after: "chmod u+w \"$TEST_DIR\"\necho continued\n"
    }) do |directory, stdout, stderr|
      assert_equal "127.0.0.1 localhost\n", File.read(File.join(directory, 'hosts'))
      assert_includes stderr, '[host-alias] WARN: failed to update /etc/hosts for snapshots.daytona.example.com'
      refute_includes stdout, '[host-alias] set'
      assert_includes stdout, 'continued'
    end
  end

  def test_failed_rename_removes_temp_file_and_warns
    with_alias_shell(installer, {
      before: <<~'SH'
        printf '10.100.0.1 service\n' > "$TEST_DIR/dns"
        mkdir "$TEST_DIR/bin" && printf '#!/bin/sh\nexit 1\n' > "$TEST_DIR/bin/mv" && chmod +x "$TEST_DIR/bin/mv"
        PATH="$TEST_DIR/bin:$PATH"
      SH
    }) do |directory, stdout, stderr|
      assert_equal "127.0.0.1 localhost\n", File.read(File.join(directory, 'hosts'))
      assert_empty Dir.glob(File.join(directory, 'hosts.*'))
      assert_includes stderr, '[host-alias] WARN: failed to update /etc/hosts for snapshots.daytona.example.com'
      refute_includes stdout, '[host-alias] set'
    end
  end

  def test_static_alias_values_are_not_evaluated_by_the_host_shell
    name = 'a$(touch "$TEST_DIR/pwned")"b'
    script = installer('services.runner.snapshotManagerInClusterRoute.enabled' => false,
                       'services.runner.hostAliases' => [{'ip' => '10.0.0.5', 'hostnames' => [name]}])
    with_alias_shell(script, {}) do |directory, _stdout, _stderr|
      refute File.exist?(File.join(directory, 'pwned'))
      assert_equal "127.0.0.1 localhost\n10.0.0.5 #{name}\n", File.read(File.join(directory, 'hosts'))
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
