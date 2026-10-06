{ prev, ... }:

{
  # GCC 16 defaults to C++20, where VersionInfo's defaulted constructor stops it being an aggregate and its brace init fails. cxx_std_17 is only a floor, so pin it.
  sonobus = prev.sonobus.overrideAttrs (oldAttrs: {
    cmakeFlags = (oldAttrs.cmakeFlags or [ ]) ++ [ "-DCMAKE_CXX_STANDARD=17" ];
  });
}
