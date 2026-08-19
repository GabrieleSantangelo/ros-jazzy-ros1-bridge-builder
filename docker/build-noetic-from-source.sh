#!/bin/bash
# Rebuild ROS 1 Noetic for the host architecture from the ppa:ros-for-jammy/noble
# source packages.
#
# The PPA only publishes amd64 binaries (276 packages for amd64, 14 arch-any
# leftovers for arm64), so `apt install ros-noetic-desktop` fails outright on a
# Jetson. The *source* packages are there for all 235 noetic entries though, and
# they already carry the maintainer's Noble port (log4cxx 1.x, Python 3.12,
# Boost 1.83), so rebuilding them natively is far cheaper than porting Noetic
# ourselves and gives bit-for-bit the same patches amd64 gets.
#
# We build ros-base + common_msgs + tf2_msgs rather than ros-noetic-desktop:
# ros1_bridge only needs roscpp and the message packages it maps, and desktop
# would drag in rviz/gazebo for no gain.

set -o errexit -o pipefail -o nounset

ORDER_FILE="${1:-/tmp/noetic-arm64-build-order.txt}"
REPO_DIR=/opt/noetic-localrepo
WORK_DIR=/tmp/noetic-src

export DEBIAN_FRONTEND=noninteractive
# Noetic's own tests need a running roscore and are not worth the wall clock.
export DEB_BUILD_OPTIONS="nocheck parallel=$(nproc)"

#-------------------------------------------------------------------------
# Scrub the ROS 2 environment the base image bakes in.
#
# catkin generates an env.sh, runs it, and ast.literal_eval()s the stdout to
# cache the build environment. ros_environment's env hook sees ROS_DISTRO=jazzy
# and prints "ROS_DISTRO was set to 'jazzy' before..." on *stdout*, which lands
# in the middle of the dict catkin is parsing:
#
#   SyntaxError: invalid syntax   <- at "ROS_DISTRO was set to 'jazzy' before"
#
# Same reason the Dockerfile unsets ROS_DISTRO before building custom_msgs.
# Nothing here is arch-specific; a from-source build on amd64 would hit it too.
#-------------------------------------------------------------------------
unset ROS_DISTRO ROS_VERSION ROS_PYTHON_VERSION AMENT_PREFIX_PATH \
      COLCON_PREFIX_PATH CMAKE_PREFIX_PATH ROS_LOCALHOST_ONLY \
      ROS_AUTOMATIC_DISCOVERY_RANGE RMW_IMPLEMENTATION
# Keep /opt/ros/jazzy off the loader and interpreter paths for the same reason.
strip_jazzy() { tr ':' '\n' <<< "${1-}" | grep -v '^/opt/ros/jazzy' | paste -sd: -; }
export LD_LIBRARY_PATH="$(strip_jazzy "${LD_LIBRARY_PATH-}")"
export PYTHONPATH="$(strip_jazzy "${PYTHONPATH-}")"
export PATH="$(strip_jazzy "$PATH")"

#-------------------------------------------------------------------------
# deb-src for the PPA, plus the tooling to build from it
#-------------------------------------------------------------------------
apt-get update
apt-get -y install --no-install-recommends \
    devscripts equivs dpkg-dev fakeroot build-essential \
    python3-all-dev dh-python

# add-apt-repository already wrote the binary entry; mirror it as deb-src.
# Newer Ubuntu uses the deb822 .sources format, older the one-line .list.
for f in /etc/apt/sources.list.d/*ros-for-jammy*; do
    case "$f" in
      *.sources) grep -q '^Types:.*deb-src' "$f" || sed -i 's/^Types: deb$/Types: deb deb-src/' "$f" ;;
      *.list)    grep -q '^deb-src' "$f" || sed -n 's/^deb /deb-src /p' "$f" >> "$f" ;;
    esac
done

#-------------------------------------------------------------------------
# Local apt repo. Each package we build lands here so that the *next*
# package's Build-Depends resolve through apt instead of us having to
# hand-install debs in the right order.
#-------------------------------------------------------------------------
mkdir -p "$REPO_DIR" "$WORK_DIR"
echo "deb [trusted=yes] file://$REPO_DIR ./" > /etc/apt/sources.list.d/noetic-local.list
refresh_repo() {
    ( cd "$REPO_DIR" && dpkg-scanpackages --multiversion . > Packages 2>/dev/null )
    apt-get update -o Dir::Etc::sourcelist=/etc/apt/sources.list.d/noetic-local.list \
                   -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0
}
refresh_repo
apt-get update

total=$(grep -cve '^\s*$' -e '^\s*#' "$ORDER_FILE")
n=0
while read -r pkg; do
    [[ -z "$pkg" || "$pkg" == \#* ]] && continue
    n=$((n + 1))
    echo "=== [$n/$total] $pkg ==="
    cd "$WORK_DIR"
    rm -rf "$pkg"; mkdir "$pkg"; cd "$pkg"

    # The repo dir is a BuildKit cache mount, so a rerun after a failure
    # partway down the list reuses everything built before it.
    if compgen -G "$REPO_DIR/${pkg}_*.deb" > /dev/null; then
        echo "already built, installing from cache"
        apt-get -y install "$pkg"
        continue
    fi

    apt-get -y build-dep "$pkg"
    apt-get -y source "$pkg"
    # apt-get source drops exactly one unpacked source tree here.
    cd "$(find . -maxdepth 1 -mindepth 1 -type d | head -1)"
    dpkg-buildpackage -us -uc -b -j"$(nproc)"

    cd ..
    # One source package can emit several binaries (foo, foo-dev, ...); install
    # all of them, since a later package may Build-Depend on any one.
    built=$(for d in ./*.deb; do dpkg-deb -f "$d" Package; done)
    mv ./*.deb "$REPO_DIR"/
    refresh_repo
    # Install now, not at the end: catkin packages locate each other through
    # /opt/ros/noetic/share at configure time, not through apt metadata.
    apt-get -y install $built

    cd "$WORK_DIR"; rm -rf "$pkg"
done < "$ORDER_FILE"

echo "=== Noetic rebuilt for $(dpkg --print-architecture): $total source packages ==="
apt-get clean
# Drop the local-repo apt entry before we exit: $REPO_DIR is a cache mount, so
# it is gone from the image and a later `apt-get update` against a now-missing
# file:// repo dies with "Method gave a blank filename".
rm -f /etc/apt/sources.list.d/noetic-local.list
# $REPO_DIR itself is deliberately left populated for reruns of this layer.
rm -rf "$WORK_DIR" /var/lib/apt/lists/*
