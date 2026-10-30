{ prev, ... }:

{
  sonobus = prev.sonobus.overrideAttrs (oldAttrs: {
    cmakeFlags = (oldAttrs.cmakeFlags or [ ]) ++ [ "-DCMAKE_CXX_STANDARD=17" ];
  });
}
