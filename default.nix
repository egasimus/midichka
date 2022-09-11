{ pkgs ? import <nixpkgs> {} }: pkgs.stdenv.mkDerivation {
  name = "midichka";
  nativeBuildInputs = with pkgs; [ zig gdb ];
  buildInputs = with pkgs; [ alsa-lib ];
}
