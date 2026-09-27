# `vestal-gtk4.pc`: GTK 4, gtk4-layer-shell, libepoxy, fontconfig and
# libwayland-client (CWaylandCapture's screen capture) as one
# flattened pkg-config module, for the CGtk4 system library target
# (Package.swift). SwiftPM's own pkg-config reader gives up when any module
# in the Requires.private closure is missing, and gtk4's closure is large
# (sysprof, libmount, xdmcp, …); pkg-config resolves it here once instead.
#
# Libs lists gtk4-layer-shell first and libwayland-client last, so the
# layer-shell library precedes libwayland in the executable's DT_NEEDED
# order, as gtk4-layer-shell requires.
{
  runCommand,
  pkg-config,
  gtk4,
  gtk4-layer-shell,
  libepoxy,
  fontconfig,
  wayland,
}:

runCommand "vestal-gtk4-pkgconfig"
  {
    nativeBuildInputs = [ pkg-config ];
    buildInputs = [
      gtk4
      gtk4-layer-shell
      libepoxy
      fontconfig
      wayland
    ];
    # The libraries themselves reach the linker through these inputs.
    propagatedBuildInputs = [
      gtk4
      gtk4-layer-shell
      libepoxy
      fontconfig
      wayland
    ];
  }
  ''
    modules="gtk4-layer-shell-0 gtk4 epoxy fontconfig"
    # SwiftPM refuses code-generation flags in Cflags (glib adds -msse etc.).
    cflags=$(pkg-config --cflags $modules wayland-client | tr ' ' '\n' | grep -v '^-m' | tr '\n' ' ')
    mkdir -p $out/lib/pkgconfig
    cat > $out/lib/pkgconfig/vestal-gtk4.pc <<EOF
    Name: vestal-gtk4
    Description: GTK 4, gtk4-layer-shell, epoxy, fontconfig and wayland-client for vestal (flattened)
    Version: 1
    Cflags: $cflags
    Libs: $(pkg-config --libs $modules) $(pkg-config --libs wayland-client)
    EOF
  ''
