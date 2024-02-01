{ stdenv, libcbor, cjson, sqlite }:

stdenv.mkDerivation {
  pname = "cbor_to_json";
  version = "0.1";

  src = ./.;

  buildInputs = [
    libcbor
    cjson
    sqlite
  ];

  buildPhase = ''
    $CC -shared -g -fPIC -Wall -Wextra -Werror \
      src/cbor_to_json.c -o cbor_to_json.so \
      -I${libcbor}/include \
      -I${cjson}/include \
      -I${sqlite.dev}/include \
      -L${libcbor}/lib \
      -L${cjson}/lib \
      -L${sqlite.dev}/lib \
      -lcbor \
      -lcjson \
      -lsqlite3
  '';
  installPhase = ''
    mkdir -p $out/lib
    cp cbor_to_json.so $out/lib
  '';
}
