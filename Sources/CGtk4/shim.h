// The C APIs VestalLinux calls (Linux only): GTK 4, gtk4-layer-shell
// (wlr-layer-shell for GTK), libepoxy (the GL loader GTK itself uses) and
// fontconfig. Flags and libraries come from `vestal-gtk4.pc`
// (nix/gtk-pkgconfig.nix).
#include <epoxy/gl.h>
#include <fontconfig/fontconfig.h>
#include <gtk/gtk.h>
#include <gtk4-layer-shell.h>
#include <glib-unix.h>
#include <sys/eventfd.h>
