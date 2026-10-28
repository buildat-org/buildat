# The Windows packaging image ([PACKAGING] step 3): Debian's mingw-w64 cross
# toolchain builds buildat.exe, buildat_server.exe and the bundled Urho3D
# (through Urho3D's own CMake/Toolchains/MinGW.cmake); Wine runs the smoke
# test. The compiler the archive ships under compiler/ is a separate,
# native MinGW-w64 distribution -- not this one, which is a Linux program
# -- pinned by URL and hash below once step 3's install rules take it.
# Pinned ([WIN_DLL_INIT]): the base image by digest and the packages from
# a snapshot.debian.org date, so two builds of one commit are one archive.
# The 0.3.0 zip that ran and the one that did not were the same source
# through an image rebuilt from unpinned packages (gcc-mingw-w64-base
# moved to 12.2.0-14+deb12u1 between them), and the difference sat in
# Urho3D.dll's DllMain. Moving the date is a deliberate commit.
FROM debian:bookworm@sha256:f37a335e82bca302e955fa39f9dfe28f1be618f016f8a2b56318e5a5111afc26
ARG DEBIAN_SNAPSHOT=20260920T000000Z
RUN rm -f /etc/apt/sources.list.d/debian.sources \
	&& printf 'deb [check-valid-until=no] http://snapshot.debian.org/archive/debian/%s bookworm main\ndeb [check-valid-until=no] http://snapshot.debian.org/archive/debian-security/%s bookworm-security main\n' "$DEBIAN_SNAPSHOT" "$DEBIAN_SNAPSHOT" > /etc/apt/sources.list \
	&& apt-get -o Acquire::Retries=5 update && apt-get install -y --no-install-recommends \
	build-essential cmake git ca-certificates ccache \
	mingw-w64 g++-mingw-w64-x86-64 binutils-mingw-w64-x86-64 \
	zip tar gzip curl xz-utils nsis \
	&& rm -rf /var/lib/apt/lists/*
# The POSIX-threads flavour of the cross compiler, for std::thread
RUN update-alternatives --set x86_64-w64-mingw32-g++ /usr/bin/x86_64-w64-mingw32-g++-posix && \
	update-alternatives --set x86_64-w64-mingw32-gcc /usr/bin/x86_64-w64-mingw32-gcc-posix
# The compiler the archive ships under compiler/: a native MinGW-w64
# distribution, winlibs' GCC 13.2 with the msvcrt runtime and POSIX
# threads, the same C runtime and thread model as Debian's cross
# toolchain above, so a module it compiles links against what that built.
# One URL and one hash; a change of either is a deliberate commit.
ARG WINLIBS_URL=https://github.com/brechtsanders/winlibs_mingw/releases/download/13.2.0posix-17.0.6-11.0.1-msvcrt-r5/winlibs-x86_64-posix-seh-gcc-13.2.0-mingw-w64msvcrt-11.0.1-r5.zip
ARG WINLIBS_SHA256=675f79b6fba8d3c8165bd9b5fb8e96ab73370dd8611f13e520cb185357d3dafc
# And Wine, for the smoke test: the server out of the archive, compiling
# a module with the compiler the archive ships, under the virtual display
# the client will want later
RUN dpkg --add-architecture i386 && apt-get -o Acquire::Retries=5 update && apt-get install -y --no-install-recommends unzip \
	wine wine64 wine32:i386 xvfb xauth libgl1-mesa-dri imagemagick \
	&& rm -rf /var/lib/apt/lists/* \
	&& curl -sSL -o /tmp/winlibs.zip "$WINLIBS_URL" \
	&& echo "$WINLIBS_SHA256  /tmp/winlibs.zip" | sha256sum -c - \
	&& mkdir -p /opt/winlibs && unzip -q /tmp/winlibs.zip -d /opt/winlibs \
	&& rm /tmp/winlibs.zip
# libcurl for the cross build ([CONTENTDB], a required dependency): Debian
# has no mingw-w64 curl package, so curl's source, built here with the
# same cross toolchain as everything else, static, TLS through Windows'
# own schannel so nothing else is needed. Not curl-for-win's prebuilt
# DLL: that one is llvm-mingw's against the UCRT, and inside an msvcrt
# process it failed to initialise on a Windows 11 desktop
# (0xc0000142, [WIN_DLL_INIT]). util/package.sh hands the paths to CMake.
ARG CURL_URL=https://curl.se/download/curl-8.22.0.tar.xz
ARG CURL_SHA256=f7ef3ae8a22e521f289803fe93543eb64c329b58aa73a9e224dfd915a2a5f4f7
RUN curl -sSL -o /tmp/curl.tar.xz "$CURL_URL" \
	&& echo "$CURL_SHA256  /tmp/curl.tar.xz" | sha256sum -c - \
	&& mkdir -p /tmp/curl && tar -xJf /tmp/curl.tar.xz -C /tmp/curl --strip-components=1 \
	&& cd /tmp/curl \
	&& ./configure --host=x86_64-w64-mingw32 --prefix=/opt/curlwin/curl \
		--disable-shared --enable-static --with-schannel --without-libpsl \
		--disable-ldap --disable-ldaps --disable-manual --disable-docs \
		--without-zlib --without-brotli --without-zstd --without-libidn2 \
		--disable-dict --disable-file --disable-ftp --disable-gopher \
		--disable-imap --disable-mqtt --disable-pop3 --disable-rtsp \
		--disable-smb --disable-smtp --disable-telnet --disable-tftp \
	&& make -j"$(nproc)" install-strip \
	&& rm -rf /tmp/curl /tmp/curl.tar.xz
# [PACKAGE_PREBUILT_WASM] The builtins' .wasm for the archive's cache
# (util/prebuild_wasm.py; a .wasm is the same for every platform, and the
# archive's server has no clang to build one): Debian's clang and lld,
# python3 to run it. Linux's image has emsdk's instead
RUN apt-get -o Acquire::Retries=5 update && apt-get install -y --no-install-recommends \
	clang lld python3 \
	&& rm -rf /var/lib/apt/lists/*
# [SERVER_WASM] cargo and Rust's wasm32-unknown-unknown target, for the
# Rust modules util/prebuild_wasm.py builds (a server module's .wasm, a
# client's wasm/): rustup's minimal profile at a pinned toolchain, which
# is what decides the .wasm; moving it is a deliberate commit
ARG RUST_TOOLCHAIN=1.94.0
RUN curl -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path \
	--profile minimal --default-toolchain "$RUST_TOOLCHAIN" \
	--target wasm32-unknown-unknown
ENV PATH=/root/.cargo/bin:$PATH
WORKDIR /work
