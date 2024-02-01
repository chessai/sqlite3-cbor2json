{
  description = "a SQLite3 extension that adds a cbor_to_json function";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs";
  };

  outputs = { self, nixpkgs, ... }:
    let
      forAllSystems = f:
        nixpkgs.lib.genAttrs [
          "x86_64-linux"
          "aarch64-linux"
          "x86_64-darwin"
          "aarch64-darwin"
        ] (system:
          f (import nixpkgs {
            inherit system;
            config = {};
            overlays = [];
          })
        );
    in
    {
       packages = forAllSystems (pkgs: {
         default = pkgs.callPackage ./cbor_to_json.nix {};
       });
    };
}
