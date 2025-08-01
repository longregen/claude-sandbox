{
  description = "Claude Sandbox - Sandboxed Claude API environment using bubblewrap";

  inputs = {
    nixpkgs.url = "git+ssh://gitea/mirrors/nixpkgs?shallow=1&ref=nixos-unstable";
    flake-utils.url = "git+ssh://gitea/mirrors/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        claude-sandbox = pkgs.callPackage ./default.nix { };
      in
      {
        packages = {
          default = claude-sandbox;
          claude-sandbox = claude-sandbox;
        };

        apps = {
          default = {
            type = "app";
            program = "${claude-sandbox}/bin/claude-sandbox";
          };
          claude-sandbox = {
            type = "app";
            program = "${claude-sandbox}/bin/claude-sandbox";
          };
          update-claude = {
            type = "app";
            program = "${pkgs.writeShellScript "update-claude" ''
              export PATH=${pkgs.lib.makeBinPath [ pkgs.curl pkgs.jq pkgs.nix pkgs.gnused ]}:$PATH
              exec ${./update-claude.sh}
            ''}";
          };
        };

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            claude-sandbox
            nodejs_22
          ];
          
          shellHook = ''
            echo "🤖 Claude Sandbox Development Environment"
          '';
        };
      });
}
