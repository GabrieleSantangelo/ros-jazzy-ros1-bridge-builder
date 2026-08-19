FROM ros:jazzy-ros-base-noble
# The above base image is multi-platform (works on ARM64 and AMD64):
# Docker will automatically select the correct platform variant based on the host's architecture.

#
# How to build this docker image:
#  docker build . -t ros-jazzy-ros1-bridge-builder
#
# How to build ros-jazzy-ros1-bridge:
#  # 0.) From a Ubuntu 24.04 (Noble) ROS 2 Jazzy system, create a "ros-jazzy-ros1-bridge/" ROS2 package:
#    docker run --rm ros-jazzy-ros1-bridge-builder | tar xvzf -
#
# How to use the ros-jazzy-ros1-bridge:
#  # 1.) First start a ROS1 Noetic docker and bring up a GUI terminal, something like:
#    rocker --x11 --user --privileged \
#         --volume /dev/shm /dev/shm --network=host -- ros:noetic-ros-base-focal \
#         'bash -c "sudo apt update; sudo apt install -y ros-noetic-rospy-tutorials tilix; tilix"'
#
#  # 2.) Then, start "roscore" inside the ROS1 container:
#    source /opt/ros/noetic/setup.bash
#    roscore
#
#  # 3.) Now, from the Ubuntu 24.04 (Noble) ROS2 Desktop Jazzy system, start the ros1 bridge node:
#    apt-get -y install ros-jazzy-desktop
#    source /opt/ros/jazzy/setup.bash
#    source ros-jazzy-ros1-bridge/install/local_setup.bash
#    ros2 run ros1_bridge dynamic_bridge
#
#  # 4.) Back to the ROS1 Noetic container, run in another terminal tab:
#    source /opt/ros/noetic/setup.bash
#    rosrun rospy_tutorials talker
#
#  # 5.) Finally, from the Ubuntu 24.04 (Noble) ROS2 Jazzy system:
#    source /opt/ros/jazzy/setup.bash
#    ros2 run demo_nodes_cpp listener
#

# Make sure bash catches errors (no need to chain commands with &&, use ; instead)
SHELL ["/bin/bash", "-o", "pipefail", "-o", "errexit", "-c"]

ARG DEBIAN_FRONTEND=noninteractive

###########################
# 1.) Bring system up to the latest ROS desktop configuration
###########################

RUN apt-get update; \
    apt-get -y install ros-jazzy-desktop; \
    rm -rf /var/lib/apt/lists/*


###########################
# 5.) Install ROS1 Noetic
# (ppa ships AMD64 binaries only; ARM64 rebuilds them from the ppa sources)
###########################

RUN apt-get update; \
    apt-get -y install software-properties-common; \
    rm -rf /var/lib/apt/lists/*
# -s also enables deb-src, which the ARM64 source rebuild below needs.
RUN add-apt-repository -y -s ppa:ros-for-jammy/noble

# The PPA publishes amd64 binaries only (276 packages for amd64, 14 arch-any
# leftovers for arm64), so on a Jetson `apt install ros-noetic-desktop` fails
# with "Unable to locate package". Its 235 *source* packages are architecture
# "any" and already carry the Noble port, so on arm64 we rebuild ros-base +
# common_msgs + tf2_msgs from those sources instead. See
# docker/build-noetic-from-source.sh for why that subset and not desktop.
COPY docker/build-noetic-from-source.sh /tmp/build-noetic-from-source.sh
COPY docker/noetic-arm64-build-order.txt /tmp/noetic-arm64-build-order.txt
# The cache mount holds the .debs we produce. Editing the script or the package
# list busts this layer, and without the cache that means recompiling all 80
# packages from scratch; with it, a rerun reinstalls what is already built and
# resumes at the package that failed.
RUN --mount=type=cache,target=/opt/noetic-localrepo,sharing=locked                     \
    if [[ $(dpkg --print-architecture) = "amd64" ]]; then                              \
      apt-get update;                                                                  \
      apt -y install ros-noetic-desktop;                                               \
      rm -rf /var/lib/apt/lists/*;                                                      \
    else                                                                               \
      /tmp/build-noetic-from-source.sh /tmp/noetic-arm64-build-order.txt;              \
    fi

# The amd64 debs ship pkgconfig files under the x86_64 triplet, which breaks the
# bridge's CMake probing when those debs are unpacked on ARM64. Packages we build
# natively already land in the aarch64 triplet, so only copy when the x86_64 dir
# is actually there.
RUN if [[ $(uname -m) = "arm64" || $(uname -m) = "aarch64" ]] &&                        \
       [[ -d /usr/lib/x86_64-linux-gnu/pkgconfig ]]; then                               \
      cp /usr/lib/x86_64-linux-gnu/pkgconfig/* /usr/lib/aarch64-linux-gnu/pkgconfig/;   \
    fi

###########################
# 6.) Compile custom msgs
###########################

COPY custom_msgs /custom_msgs
RUN \
    # Build the ros1 workspace
    cd /custom_msgs/custom_msgs_ros1_ws && \
    unset ROS_DISTRO && \
    source /opt/ros/noetic/setup.bash && \
    time colcon build --cmake-args -DCMAKE_BUILD_TYPE=Release && \
    # Build the ros2 workspace
    cd /custom_msgs/custom_msgs_ros2_ws && \
    unset ROS_DISTRO && \
    source /opt/ros/jazzy/setup.bash && \
    time colcon build --cmake-args -DCMAKE_BUILD_TYPE=Release

###########################
# 7.) Compile ros1_bridge
###########################

# g++-11 and needed
RUN apt-get update; \
    apt-get -y install g++-11 gcc-11; \
    update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-11 11; \
    update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-11 11; \
    rm -rf /var/lib/apt/lists/*

COPY docker/patches/tf_static_2to1.patch /tmp/tf_static_2to1.patch

RUN                                                                                    \
    #-------------------------------------                                             \
    # Get the Bridge code                                                              \
    #-------------------------------------                                             \
    mkdir -p /ros-jazzy-ros1-bridge/src;                                               \
    cd /ros-jazzy-ros1-bridge/src;                                                     \
    git clone -b action_bridge_humble https://github.com/smith-doug/ros1_bridge.git;   \
    cd ros1_bridge/;                                                                   \
                                                                                       \
    #-------------------------------------                                             \
    # TEST: custom fix for /tf_static 2to1 latching (upstream #424 fixes QoS/latch    \
    # but still drops frames when multiple static broadcasters exist - see commit    \
    # message for the full writeup). This aggregates transforms by child_frame_id    \
    # instead of naively forwarding each message through the shared latch.           \
    #-------------------------------------                                             \
    git apply /tmp/tf_static_2to1.patch;                                               \
                                                                                       \
    #-------------------------------------                                             \
    # Apply the ROS1 and ROS2 underlays                                                \
    #-------------------------------------                                             \
    source /opt/ros/noetic/setup.bash;                                                 \
    source /opt/ros/jazzy/setup.bash;                                                  \
                                                                                       \
    #-------------------------------------                                             \
    # Apply the ROS1 and ROS2 overlays                                                 \
    #-------------------------------------                                             \
    source /custom_msgs/custom_msgs_ros1_ws/install/local_setup.bash;                  \
    source /custom_msgs/custom_msgs_ros2_ws/install/local_setup.bash;                  \
                                                                                       \
    #-------------------------------------                                             \
    # Finally, build the Bridge                                                        \
    #-------------------------------------                                             \
    MEMG=$(printf "%.0f" $(free -g | awk '/^Mem:/{print $2}'));                        \
    NPROC=$(nproc);  MIN=$((MEMG<NPROC ? MEMG : NPROC));                               \
    cd /ros-jazzy-ros1-bridge/;                                                        \
    echo "Please wait...  running $MIN concurrent jobs to build ros1_bridge";          \
    time ROS_DISTRO=humble MAKEFLAGS="-j $MIN" colcon build                            \
        --event-handlers console_direct+                                               \
        --cmake-args -DCMAKE_BUILD_TYPE=Release

###########################
# 9.) Pack all ROS1 dependent libraries
###########################
# fix ARM64 pkgconfig path issue -- Fix provided by ambrosekwok 
RUN if [[ $(uname -m) = "arm64" || $(uname -m) = "aarch64" ]] &&                       \
       [[ -d /usr/lib/x86_64-linux-gnu/pkgconfig ]]; then                              \
      cp /usr/lib/x86_64-linux-gnu/pkgconfig/* /usr/lib/aarch64-linux-gnu/pkgconfig/;  \
    fi

RUN ROS1_LIBS="libactionlib.so";                                                \
    ROS1_LIBS="$ROS1_LIBS libroscpp.so";                                        \
    ROS1_LIBS="$ROS1_LIBS librosconsole.so";                                    \
    ROS1_LIBS="$ROS1_LIBS libroscpp_serialization.so";                          \
    ROS1_LIBS="$ROS1_LIBS librostime.so";                                       \
    ROS1_LIBS="$ROS1_LIBS libxmlrpcpp.so";                                      \
    ROS1_LIBS="$ROS1_LIBS libcpp_common.so";                                    \
    ROS1_LIBS="$ROS1_LIBS librosconsole_log4cxx.so";                            \
    ROS1_LIBS="$ROS1_LIBS librosconsole_backend_interface.so";                  \
    ROS1_LIBS="$ROS1_LIBS liblog4cxx.so.15";                                    \
    ROS1_LIBS="$ROS1_LIBS libaprutil-1.so.0";                                   \
    ROS1_LIBS="$ROS1_LIBS libapr-1.so.0";                                       \
    cd /ros-jazzy-ros1-bridge/install/ros1_bridge/lib;                          \
    source /opt/ros/noetic/setup.bash;                                          \
    for soFile in $ROS1_LIBS; do                                                \
      soFilePath=$(ldd libros1_bridge.so | grep $soFile | awk '{print $3;}');   \
      cp -L $soFilePath ./;                                                     \
    done

###########################
# 10.) Spit out ros1_bridge tarball by default when no command is given
###########################
RUN tar czf /ros-jazzy-ros1-bridge.tgz \
     --exclude '*/build/*' --exclude '*/src/*' \
     /ros-jazzy-ros1-bridge \
     /custom_msgs/custom_msgs_ros2_ws/install
ENTRYPOINT []
CMD cat /ros-jazzy-ros1-bridge.tgz; sync
