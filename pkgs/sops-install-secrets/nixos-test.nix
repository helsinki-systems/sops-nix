{ makeTest ? import <nixpkgs/nixos/tests/make-test-python.nix>, pkgs ? import <nixpkgs> }:
{
 ssh-keys = makeTest {
  name = "sops-ssh-keys";
  nodes.server = { ... }: {
    imports = [ ../../modules/sops ];
    services.openssh.enable = true;
    services.openssh.hostKeys = [{
      type = "rsa";
      bits = 4096;
      path = ./test-assets/ssh-key;
    }];
    sops.defaultSopsFile = ./test-assets/secrets.yaml;
    sops.secrets.test_key = {};
  };

  testScript = ''
    start_all()
    server.succeed("cat /run/secrets/test_key | grep -q test_value")
  '';
 } {
   inherit pkgs;
   inherit (pkgs) system;
 };

 age-keys = makeTest {
  name = "sops-age-keys";
  machine = {
    imports = [ ../../modules/sops ];
    sops = {
      age.keyFile = ./test-assets/age-keys.txt;
      defaultSopsFile = ./test-assets/secrets.yaml;
      secrets.test_key = {};
    };
  };

  testScript = ''
    start_all()
    machine.succeed("cat /run/secrets/test_key | grep -q test_value")
  '';
  } {
    inherit pkgs;
    inherit (pkgs) system;
  };

  age-ssh-keys = makeTest {
  name = "sops-age-ssh-keys";
  machine = {
    imports = [ ../../modules/sops ];
    services.openssh.enable = true;
    services.openssh.hostKeys = [{
      type = "ed25519";
      path = ./test-assets/ssh-ed25519-key;
    }];
    sops = {
      defaultSopsFile = ./test-assets/secrets.yaml;
      secrets.test_key = {};
    };
  };

  testScript = ''
    start_all()
    machine.succeed("cat /run/secrets/test_key | grep -q test_value")
  '';
  } {
    inherit pkgs;
    inherit (pkgs) system;
  };

 pgp-keys = makeTest {
   name = "sops-pgp-keys";
   nodes.server = { pkgs, lib, config, ... }: {
     imports = [
       ../../modules/sops
     ];

     users.users.someuser.isSystemUser = true;

     sops.gnupg.home = "/run/gpghome";
     sops.defaultSopsFile = ./test-assets/secrets.yaml;
     sops.secrets.test_key.owner = config.users.users.someuser.name;
     sops.secrets.existing-file = {
       key = "test_key";
       path = "/run/existing-file";
     };
     # must run before sops
     system.activationScripts.gnupghome = lib.stringAfter [ "etc" ] ''
       cp -r ${./test-assets/gnupghome} /run/gpghome
       chmod -R 700 /run/gpghome

       touch /run/existing-file
     '';
     # Useful for debugging
     #environment.systemPackages = [ pkgs.gnupg pkgs.sops ];
     #environment.variables = {
     #  GNUPGHOME = "/run/gpghome";
     #  SOPS_GPG_EXEC="${pkgs.gnupg}/bin/gpg";
     #  SOPSFILE = "${./test-assets/secrets.yaml}";
     #};
  };
  testScript = ''
    def assertEqual(exp: str, act: str) -> None:
        if exp != act:
            raise Exception(f"'{exp}' != '{act}'")


    start_all()

    value = server.succeed("cat /run/secrets/test_key")
    assertEqual("test_value", value)

    server.succeed("runuser -u someuser -- cat /run/secrets/test_key >&2")

    target = server.succeed("readlink -f /run/existing-file")
    assertEqual("/run/secrets.d/1/existing-file", target.strip())
  '';
 } {
   inherit pkgs;
   inherit (pkgs) system;
 };

  restart-and-reload = makeTest {
    # TODO Migrate to age
    name = "sops-restart-and-reload";
    machine = { pkgs, lib, config, ... }: {
      imports = [
        ../../modules/sops
      ];

      sops.gnupgHome = "/run/gpghome";
      sops.defaultSopsFile = ./test-assets/secrets.yaml;
      sops.secrets.test_key = {
        restartUnits = [ "restart-unit.service" ];
        reloadUnits = [ "reload-unit.service" ];
      };
      # must run before sops
      system.activationScripts.gnupghome = lib.stringAfter [ "etc" ] ''
        cp -r ${./test-assets/gnupghome} /run/gpghome
        chmod -R 700 /run/gpghome
      '';

      systemd.services."restart-unit" = {
        description = "Restart unit";
        # not started on boot
        serviceConfig = {
          ExecStart = "/bin/sh -c 'echo ok > /restarted'";
        };
      };
      systemd.services."reload-unit" = {
        description = "Restart unit";
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "/bin/sh -c true";
          ExecReload = "/bin/sh -c 'echo ok > /reloaded'";
        };
      };
   };
   testScript = ''
     machine.wait_for_unit("multi-user.target")
     machine.fail("test -f /restarted")
     machine.fail("test -f /reloaded")

     # Nothing is to be restarted after boot
     machine.fail("ls /run/systemd/sops-*")

     # Nothing happens when the secret is not changed
     machine.succeed("/run/current-system/bin/switch-to-configuration test")
     machine.fail("test -f /restarted")
     machine.fail("test -f /reloaded")

     # Ensure the secret is changed
     machine.succeed(": > /run/secrets/test_key")

     # The secret is changed, now something should happen
     machine.succeed("/run/current-system/bin/switch-to-configuration test")

     # Ensure something happened
     machine.succeed("test -f /restarted")
     machine.succeed("test -f /reloaded")
   '';
  } {
    inherit pkgs;
    inherit (pkgs) system;
  };
}
