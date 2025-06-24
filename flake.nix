{
  description = "Claude Sandbox - Sandboxed Claude API environment using bubblewrap";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
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
