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

## SOPS-backed vault key

This package can bypass Linux Secret Service/keytar for the Anytype vault key
and read it from a root-managed file such as a `sops-nix` secret.

Make the vault key and account id available as runtime secret files, readable by
the user that launches Anytype:

```nix
{ config, pkgs, ... }:

{
  sops.secrets."anytype/vault_key" = {
    owner = "alice";
    mode = "0400";
  };

  sops.secrets."anytype/account_id" = {
    owner = "alice";
    mode = "0400";
  };

  environment.systemPackages = [
    (pkgs.anytype.override {
      vaultKeyFile = config.sops.secrets."anytype/vault_key".path;
      vaultKeyAccountIdFile = config.sops.secrets."anytype/account_id".path;
    })
  ];
}
```

The example above expects secret names shaped like:

```yaml
anytype:
  vault_key: ENC[...]
  account_id: ENC[...]
```

`vaultKeyAccountIdFile` must point to a file containing the Anytype account id,
not a space id. For an existing profile it is usually available with:

```bash
jq -r .accountId ~/.config/anytype/localStorage-dev.json
```

If you do not keep the account id in SOPS, a literal account id is also
supported:

```nix
vaultKeyAccountId = "YOUR_ANYTYPE_ACCOUNT_ID";
```

Only file paths and literal account ids are embedded in the Nix store. Secret
contents stay outside the Nix store and are read at runtime.

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
