#pragma once
#include <string>
#include <vector>
#include <map>

struct Ebuild {
    std::string name;
    std::string version;
    std::string description;
    std::string homepage;
    std::string src_uri;
    std::vector<std::string> rdepend;
    std::vector<std::string> depend;
};

struct PkgFile {
    std::string name;
    std::string version;
    std::string description;
    std::string url;
    std::string category;
    std::vector<std::string> depends;
    std::string install_script;
};

// Gentoo category/atom -> Galactica package name
// Format: "category/atom" or just "atom" for catch-all
static const std::map<std::string, std::string> GENTOO_TO_GALACTICA = {
    // libs
    {"dev-libs/glib",                   "glib2"},
    {"dev-libs/libffi",                 "libffi"},
    {"dev-libs/libpcre",                "pcre"},
    {"dev-libs/libpcre2",               "pcre2"},
    {"dev-libs/openssl",                "openssl"},
    {"dev-libs/json-c",                 "json-c"},
    {"dev-libs/libxml2",                "libxml2"},
    {"dev-libs/libxslt",                "libxslt"},
    {"dev-libs/expat",                  "expat"},
    {"dev-libs/libbsd",                 "libbsd"},
    {"dev-libs/libevent",               "libevent"},
    {"dev-libs/libusb",                 "libusb"},
    {"dev-libs/nspr",                   "nspr"},
    {"dev-libs/nss",                    "nss"},
    {"dev-libs/wayland",                "wayland"},
    {"dev-libs/wayland-protocols",      "wayland-protocols"},
    // x11/wayland
    {"x11-libs/libX11",                 "libx11"},
    {"x11-libs/libXext",                "libxext"},
    {"x11-libs/libXcursor",             "libxcursor"},
    {"x11-libs/libXi",                  "libxi"},
    {"x11-libs/libXinerama",            "libxinerama"},
    {"x11-libs/libXrandr",              "libxrandr"},
    {"x11-libs/libXrender",             "libxrender"},
    {"x11-libs/libXfixes",              "libxfixes"},
    {"x11-libs/libxcb",                 "libxcb"},
    {"x11-libs/xcb-util",               "xcb-util"},
    {"x11-libs/xcb-util-icccm",         "xcb-util-icccm"},
    {"x11-libs/xcb-util-wm",            "xcb-util-wm"},
    {"x11-libs/xcb-util-keysyms",       "xcb-util-keysyms"},
    {"x11-libs/xcb-util-image",         "xcb-util-image"},
    {"x11-libs/libxkbcommon",           "libxkbcommon"},
    {"x11-libs/cairo",                  "cairo"},
    {"x11-libs/pango",                  "pango"},
    {"x11-libs/pixman",                 "pixman"},
    {"x11-libs/gtk+",                   "gtk3"},
    {"x11-libs/gtk+:3",                 "gtk3"},
    {"x11-libs/gtk+:4",                 "gtk4"},
    {"x11-libs/gdk-pixbuf",             "gdk-pixbuf2"},
    {"x11-apps/xwayland",               "xorg-xwayland"},
    // media
    {"media-libs/mesa",                 "mesa"},
    {"media-libs/libpng",               "libpng"},
    {"media-libs/libjpeg-turbo",        "libjpeg-turbo"},
    {"media-libs/libwebp",              "libwebp"},
    {"media-libs/freetype",             "freetype2"},
    {"media-libs/fontconfig",           "fontconfig"},
    {"media-libs/harfbuzz",             "harfbuzz"},
    {"media-libs/alsa-lib",             "alsa-lib"},
    {"media-libs/libpulse",             "libpulse"},
    {"media-libs/pipewire",             "pipewire"},
    {"media-video/ffmpeg",              "ffmpeg"},
    // sys
    {"sys-libs/glibc",                  "glibc"},
    {"sys-libs/zlib",                   "zlib"},
    {"sys-libs/libcap",                 "libcap"},
    {"sys-libs/pam",                    "pam"},
    {"sys-apps/dbus",                   "dbus"},
    {"sys-apps/systemd",                ""},          // skip
    {"sys-apps/udev",                   "eudev"},
    {"sys-fs/udev",                     "eudev"},
    {"sys-libs/libdrm",                 "libdrm"},
    // net
    {"net-libs/gnutls",                 "gnutls"},
    {"net-libs/libsoup",                "libsoup"},
    {"net-misc/curl",                   "curl"},
    // wlroots family
    {"gui-libs/wlroots",                "wlroots0.18"},
    {"gui-libs/wlroots:0.18",           "wlroots0.18"},
    {"gui-libs/wlroots:0.17",           "wlroots0.17"},
    // util
    {"dev-util/pkgconf",                "pkgconf"},
    {"dev-util/cmake",                  "cmake"},
    {"dev-util/meson",                  "meson"},
    {"dev-util/ninja",                  "ninja"},
};

// Gentoo categories that are purely build-time tools — skip from runtime deps
static const std::vector<std::string> BUILD_ONLY_CATEGORIES = {
    "dev-util", "app-arch", "sys-devel",
};