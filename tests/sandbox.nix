{ pkgs, claude-sandbox }:
pkgs.testers.nixosTest {
  name = "claude-sandbox";

  nodes.machine = { pkgs, ... }: {
    virtualisation.vlans = [ 1 2 ];
    environment.systemPackages = [ claude-sandbox pkgs.curl ];
    security.unprivilegedUsernsClone = true;
    users.users.testuser = { isNormalUser = true; home = "/home/testuser"; };
  };

  nodes.blocked = { pkgs, ... }: {
    virtualisation.vlans = [ 1 ];
    networking.firewall.allowedTCPPorts = [ 8080 ];
    systemd.services.http = {
      wantedBy = [ "multi-user.target" ];
      script = ''
        echo 'you-should-not-see-this' > /tmp/index.html
        ${pkgs.python3}/bin/python3 -m http.server 8080 -d /tmp
      '';
    };
  };

  nodes.server = { pkgs, ... }: {
    virtualisation.vlans = [ 2 ];
    networking.firewall.allowedTCPPorts = [ 1080 8080 ];
    environment.systemPackages = [ pkgs.microsocks ];
    systemd.services.microsocks = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = "${pkgs.microsocks}/bin/microsocks -p 1080";
    };
    systemd.services.http = {
      wantedBy = [ "multi-user.target" ];
      script = ''
        echo 'proxy-test-ok' > /tmp/index.html
        ${pkgs.python3}/bin/python3 -m http.server 8080 -d /tmp
      '';
    };
  };

  nodes.another = { pkgs, ... }: {
    virtualisation.vlans = [ 2 ];
    networking.firewall.allowedTCPPorts = [ 8080 ];
    systemd.services.http = {
      wantedBy = [ "multi-user.target" ];
      script = ''
        echo 'another-test-ok' > /tmp/index.html
        ${pkgs.python3}/bin/python3 -m http.server 8080 -d /tmp
      '';
    };
  };

  # START_SHELL=1 drops arguments after --, so pipe commands via stdin
  testScript = ''
    start_all()
    machine.wait_for_unit("multi-user.target")
    server.wait_for_unit("microsocks.service")
    server.wait_for_unit("http.service")
    blocked.wait_for_unit("http.service")
    another.wait_for_unit("http.service")
    server.wait_for_open_port(1080)
    server.wait_for_open_port(8080)
    blocked.wait_for_open_port(8080)
    another.wait_for_open_port(8080)

    blocked_ip = blocked.succeed("ip -4 addr show eth1 | grep -oP 'inet \\K[^/]+'").strip()
    server_ip = server.succeed("ip -4 addr show eth1 | grep -oP 'inet \\K[^/]+'").strip()
    another_ip = another.succeed("ip -4 addr show eth1 | grep -oP 'inet \\K[^/]+'").strip()

    # Sanity: machine can reach both blocked (VLAN 1) and server (VLAN 2)
    machine.succeed(f"ping -c 1 {blocked_ip}")
    machine.succeed(f"ping -c 1 {server_ip}")
    # Sanity: server has no route to blocked (different VLANs)
    server.fail(f"ping -c 1 -W 3 {blocked_ip}")

    # Test 1: Basic sandbox runs
    machine.succeed("echo 'echo hello' | su - testuser -c 'cd /home/testuser && START_SHELL=1 claude-sandbox' | grep -q hello")

    # Test 2: Filesystem isolation - create a secret file, verify it's not visible
    machine.succeed("echo secret > /root/secret.txt")
    machine.fail("echo 'cat /root/secret.txt' | su - testuser -c 'cd /home/testuser && START_SHELL=1 claude-sandbox'")

    # Test 3: Network works in normal mode (--share-net)
    machine.succeed("echo 'ip link show lo' | su - testuser -c 'cd /home/testuser && START_SHELL=1 claude-sandbox'")

    # Test 4: SOCKS proxy mode - proxy on server (VLAN 2 only)
    # 4a: Verify the tunclaude interface and default route exist
    machine.succeed(f"echo 'ip link show tunclaude' | su - testuser -c 'cd /home/testuser && START_SHELL=1 claude-sandbox --socks-proxy {server_ip}:1080'")
    out = machine.succeed(f"echo 'ip route show; ip link show; cat /proc/net/route' | su - testuser -c 'cd /home/testuser && START_SHELL=1 claude-sandbox --socks-proxy {server_ip}:1080'")
    machine.log(f"BWRAP_NET_DEBUG: {out}")
    assert "default dev tunclaude" in out, f"Expected 'default dev tunclaude' in:\n{out}"

    # 4b: Sandbox can reach "server" through the SOCKS proxy
    machine.succeed(f"echo 'curl -sf http://{server_ip}:8080/index.html' | su - testuser -c 'cd /home/testuser && START_SHELL=1 claude-sandbox --socks-proxy {server_ip}:1080' | grep -q proxy-test-ok")

    # 4c: Sandbox can reach "another" through the SOCKS proxy (server routes to VLAN 2)
    machine.succeed(f"echo 'curl -sf http://{another_ip}:8080/index.html' | su - testuser -c 'cd /home/testuser && START_SHELL=1 claude-sandbox --socks-proxy {server_ip}:1080' | grep -q another-test-ok")

    # 4d: Without --socks-proxy, sandbox uses host network and can reach everything
    machine.succeed(f"echo 'curl -sf http://{server_ip}:8080/index.html' | su - testuser -c 'cd /home/testuser && START_SHELL=1 claude-sandbox' | grep -q proxy-test-ok")
    machine.succeed(f"echo 'curl -sf http://{blocked_ip}:8080/index.html' | su - testuser -c 'cd /home/testuser && START_SHELL=1 claude-sandbox' | grep -q you-should-not-see-this")

    # Test 5: SOCKS proxy mode enforces network boundary
    # 5a: Sandbox CANNOT reach "blocked" - server has no route to VLAN 1
    #     (yet machine itself can, proving the namespace isolation is what blocks it)
    machine.fail(f"echo 'curl -sf --max-time 5 http://{blocked_ip}:8080/index.html' | su - testuser -c 'cd /home/testuser && START_SHELL=1 claude-sandbox --socks-proxy {server_ip}:1080'")

    # 5b: localhost inside the sandbox is isolated (own network namespace)
    machine.fail(f"echo 'curl -sf --max-time 5 http://127.0.0.1:8080/index.html' | su - testuser -c 'cd /home/testuser && START_SHELL=1 claude-sandbox --socks-proxy {server_ip}:1080'")
  '';
}
