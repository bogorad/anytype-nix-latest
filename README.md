# anytype-nix-latest

Standalone flake that packages the latest stable Anytype desktop release for
Nix.

The package is based on the current nixpkgs Anytype expression, with repo-local
automation that polls upstream Anytype releases and refreshes hashes.

## Build

```bash
nix build .#anytype --print-build-logs
```

## Run

```bash
nix run .#anytype
```

Or run it directly from GitHub:

```bash
nix run github:bogorad/anytype-nix-latest
```

## Update

```bash
scripts/update-anytype.sh
```

The updater checks the latest stable `anyproto/anytype-ts` release, derives the
matching `anytype-heart` version from `middleware.version`, refreshes source
hashes, discovers the Go vendor hash and Bun `node_modules` hash through Nix,
and leaves the working tree unchanged when there is no newer release.

## Overlay

```nix
{
  inputs.anytype-nix-latest.url = "path:/home/chuck/git/anytype-nix-latest";

  outputs = { nixpkgs, anytype-nix-latest, ... }: {
    nixosConfigurations.example = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ({ ... }: {
          nixpkgs.overlays = [ anytype-nix-latest.overlays.default ];
        })
      ];
    };
  };
}
```
