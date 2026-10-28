# The Linux packaging image ([PACKAGING] in doc/plan/packaging_plan.md):
# Debian oldstable, the oldest glibc worth supporting, so the tarball built
# here runs on newer distros; the build dependencies README.md names, and
# what util/package.sh's smoke test needs -- a virtual display for the
# client, ImageMagick to read its screenshot, zip and tar for the archives.
# And what the checks need ([CI_RUNS]): python3 with PIL, which is how a
# runner reads the frames it shot, and lua, which is how a room asserts
# its own description before a client is started -- without them half
# the quick tier failed in two seconds with "command not found", which
# is what the first run of util/checks_in_docker.sh said (2026-09-24).
# curl and ss (iproute2): runners fetch their own server's pages and wait
# on a port; without them seven runners failed in the ci tier (2026-10-14).
# Nothing of the host's tree is built here: util/package_in_docker.sh hands
# the container a git archive of the commit and takes the archives back.
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
	libx11-dev libxrandr-dev libasound2-dev libgl1-mesa-dev \
	libcurl4-openssl-dev \
	xvfb xauth libgl1-mesa-dri imagemagick zip tar gzip \
	python3 python3-pil lua5.1 curl iproute2 \
	xz-utils patchelf \
	&& ln -sf /usr/bin/lua5.1 /usr/local/bin/lua \
	&& rm -rf /var/lib/apt/lists/*
# The web client's toolchain ([WEB_CLIENT], [LINUX_SERVER]): emsdk at its
# own tag and the SDK of the same version, which is what the bundled
# Urho3D's web build is pinned to (doc/plan/web_client_plan.md
# [WEB_EMSDK]). util/build_web.sh finds it through EMSDK.
ARG EMSDK_VERSION=3.1.60
RUN git clone --depth 1 --branch "$EMSDK_VERSION" https://github.com/emscripten-core/emsdk.git /opt/emsdk \
	&& /opt/emsdk/emsdk install "$EMSDK_VERSION" \
	&& /opt/emsdk/emsdk activate "$EMSDK_VERSION" \
	&& rm -rf /opt/emsdk/downloads
ENV EMSDK=/opt/emsdk
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
