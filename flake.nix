{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig-overlay.url = "github:mitchellh/zig-overlay";
    zls.url = "github:zigtools/zls?ref=0.16.0";
  };

  outputs =
    { self, nixpkgs, flake-utils, zig-overlay, zls, ... }:
    flake-utils.lib.eachDefaultSystem(
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        pkgzig = zig-overlay.packages.${system}."0.16.0";
        pkgzls = zls.packages.${system}.default;
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = [ pkgzig pkgzls pkgs.postgresql pkgs.pkg-config ];
        };
      }
    );
}
