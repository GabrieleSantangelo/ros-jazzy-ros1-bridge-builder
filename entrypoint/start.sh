#!/bin/bash
# Entry point for the bridge container (see `make run`).
#
# Three processes are started:
#   1. tf_static_repeater.py  -- merges /tf_static from every ROS 2 static
#      broadcaster into one latched message, because the 2-to-1 bridge
#      collapses them onto a single ROS 1 latch and would otherwise drop all
#      but the last publisher's transforms.
#   2. parameter_bridge (services)  -- services_2_to_1 / services_1_to_2 only.
#   3. parameter_bridge (topics)    -- topics only, runs in the foreground so
#      the container lives and dies with it.
#
# Why 2 and 3 are separate processes:
#   parameter_bridge runs every ROS 2 callback on ONE SingleThreadedExecutor
#   (the spin_node_once loop at the end of src/parameter_bridge.cpp). A
#   services_2_to_1 bridge serves a ROS 2 request by making a *blocking*
#   ros::ServiceClient::call() from inside that executor
#   (factory.hpp::forward_2_to_1, no timeout). While that call is pending the
#   single thread is stuck, so no ROS 2 -> ROS 1 topic gets forwarded --
#   including /clock. A ROS 1 server on use_sim_time then waits forever for a
#   clock only the blocked bridge could deliver, and the call never returns.
#   One executor per concern breaks the cycle.

set -u

ENTRYPOINT_DIR="$(dirname "$(readlink -f "$0")")"

CONFIG="${ENTRYPOINT_DIR}/bridge_topics.yaml"
if [ ! -f "${CONFIG}" ]; then
    echo "missing ${CONFIG} -- it is deployment specific and gitignored." >&2
    echo "run: cp entrypoint/bridge_topics.example.yaml entrypoint/bridge_topics.yaml" >&2
    exit 1
fi

# parameter_bridge reads its config from the ROS 1 parameter server, not from
# a file, so the YAML has to be pushed there first.
python3 "${ENTRYPOINT_DIR}/tf_static_repeater.py" &
python3 "${ENTRYPOINT_DIR}/load_ros1_params.py" "${CONFIG}"

# parameter_bridge's 3 positional arguments are the *names of the ROS 1
# parameters* it should read, in order: topics, services_1_to_2,
# services_2_to_1. Passing a name that was never set on the parameter server
# makes it print "doesn't exist or isn't an array" and skip that category --
# that is how each process ignores the other's half of the config.
#
# `__name:=` is a ROS 1 remapping: without it both processes would register as
# /ros_bridge and the second would evict the first from the ROS 1 master.
# It cannot be paired with a ROS 2 `--ros-args -r __node:=...`: ros::init()
# strips every `x:=y` token out of argv before rclcpp::init() sees it, which
# would leave a dangling `-r` and abort rcl argument parsing.
ros2 run ros1_bridge parameter_bridge \
    no_topics services_1_to_2 services_2_to_1 \
    __name:=ros_bridge_services &
SERVICES_PID=$!

ros2 run ros1_bridge parameter_bridge \
    topics no_services_1_to_2 no_services_2_to_1 &
TOPICS_PID=$!

# Exit as soon as either bridge dies instead of leaving a half-working
# container up. forward_2_to_1 throws out of its callback when a ROS 1 call
# fails, which kills the services process, so a silent death is a real case.
wait -n "${SERVICES_PID}" "${TOPICS_PID}"
echo "a parameter_bridge process exited -- shutting down" >&2
kill "${SERVICES_PID}" "${TOPICS_PID}" 2>/dev/null
wait
