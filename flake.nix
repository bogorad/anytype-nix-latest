{
  description = "Latest Anytype packaging, backported as a standalone flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  };

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;

      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      forAllSystems = lib.genAttrs systems;

      pkgsFor =
        system:
        import nixpkgs {
          inherit system;
          config.allowUnfree = true;
          overlays = [ self.overlays.default ];
        };
    in
    {
      overlays.default = final: prev: {
        anytype-heart = final.callPackage ./pkgs/anytype-heart/package.nix { };
        anytype = final.callPackage ./pkgs/anytype/package.nix {
          anytype-heart = final.anytype-heart;
        };
      };

      packages = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = pkgs.anytype;
          anytype = pkgs.anytype;
          anytype-heart = pkgs.anytype-heart;
        }
      );

      apps = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = {
            type = "app";
            program = lib.getExe pkgs.anytype;
            meta.description = "Run Anytype";
          };
          anytype = {
            type = "app";
            program = lib.getExe pkgs.anytype;
            meta.description = "Run Anytype";
          };
        }
      );

      formatter = forAllSystems (system: (pkgsFor system).nixfmt);
    };
}
