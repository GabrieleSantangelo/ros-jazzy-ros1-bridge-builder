#!/usr/bin/env python3
# This image has no ROS 1 Python tooling (no `rosparam` CLI), only the
# compiled ros1_bridge C++ libraries. parameter_bridge reads its "topics" /
# "services_1_to_2" / "services_2_to_1" config from the ROS 1 parameter
# server at startup (not from a file), so something has to push the YAML
# there first. This does it with a raw XML-RPC call to the ROS 1 master,
# which is the parameter server too.
#
# Three knobs come in as environment variables (set from the Makefile, see
# `make run NAMESPACE=... USE_SIM_TIME=...`), so one YAML can serve several
# robots without being edited:
#
#   BRIDGE_NAMESPACE   -- replaces the "{ns}" placeholder in every "topic"
#                         and "service" name. Empty means no namespace, and
#                         the leftover slash collapses: "/{ns}/odom" -> "/odom".
#   BRIDGE_ROS1_NAMESPACE -- replaces "{ros1_ns}", which only appears in the
#                         optional "ros1_topic"/"ros1_service" keys. Defaults
#                         to BRIDGE_NAMESPACE, i.e. same name on both sides.
#   BRIDGE_USE_SIM_TIME -- when false, entries marked "when: sim_time" (i.e.
#                         /clock) are dropped instead of being bridged.
#
# Different names on the two sides
# -------------------------------
# parameter_bridge builds both endpoints of a bridge from ONE name
# (create_bidirectional_bridge / service_bridge_2_to_1 in
# src/parameter_bridge.cpp take a single topic_name), so a robot whose ROS 1
# stack answers on /anymal/... cannot appear as /robot0/... in the ROS 2 fleet
# graph through the config alone.
#
# ROS 1 static remapping closes that gap, and only touches the ROS 1 endpoint:
# ros::init() strips every "a:=b" token out of argv before rclcpp::init() sees
# it, so passing "<ros2_name>:=<ros1_name>" on parameter_bridge's command line
# renames what it advertises/subscribes on the ROS 1 master while the ROS 2
# side keeps the name from this file. Verified on both a topic and a
# services_2_to_1 entry.
#
# So: "topic"/"service" always hold the ROS 2 name, and an optional
# "ros1_topic"/"ros1_service" holds the ROS 1 one. This script pushes the ROS 2
# names to the parameter server and writes the matching remap tokens to
# --remap-dir, where start.sh picks them up for the two parameter_bridge
# processes.
import os
import re
import sys
import time
import xmlrpc.client

import yaml

CALLER_ID = "/bridge_config_loader"

# Config keys holding a list of bridge entries. Everything else in the YAML
# is pushed to the parameter server untouched.
ENTRY_LISTS = ("topics", "services_1_to_2", "services_2_to_1")

# Per-entry keys naming a ROS resource, i.e. the ones {ns} applies to. These
# always hold the ROS 2 name.
NAME_KEYS = ("topic", "service")

# Optional per-entry keys naming the ROS 1 side of the same resource when it
# differs. Popped before the entry reaches the parameter server: they turn into
# command line remaps instead, and parameter_bridge has no idea about them.
# Which parameter_bridge process gets the remap follows the key, since the two
# processes split topics from services.
ROS1_NAME_KEYS = {"topic": "ros1_topic", "service": "ros1_service"}
REMAP_FILES = {"topic": "topics.remaps", "service": "services.remaps"}

# Values accepted for BRIDGE_USE_SIM_TIME.
TRUE_VALUES = {"1", "true", "yes", "on"}
FALSE_VALUES = {"0", "false", "no", "off", ""}


def env_flag(name, default):
    raw = os.environ.get(name)
    if raw is None:
        return default
    value = raw.strip().lower()
    if value in TRUE_VALUES:
        return True
    if value in FALSE_VALUES:
        return False
    sys.exit(f"{name}: expected a boolean, got '{raw}'")


def apply_namespace(name, namespace, ros1_namespace):
    """Expand {ns}/{ros1_ns} and clean up the slashes an empty one leaves behind."""
    expanded = name.replace("{ns}", namespace).replace("{ros1_ns}", ros1_namespace)
    expanded = re.sub("/{2,}", "/", expanded)
    return expanded.rstrip("/") if len(expanded) > 1 else expanded


def keep(entry, use_sim_time):
    """Evaluate an entry's optional "when:" condition, stripping it either way.

    The key is removed even when it holds, so parameter_bridge never sees a
    field it has no idea about.
    """
    condition = entry.pop("when", None)
    if condition is None:
        return True
    if condition == "sim_time":
        return use_sim_time
    sys.exit(f"unknown 'when' condition '{condition}' on entry {entry}")


def resolve(config, namespace, ros1_namespace, use_sim_time):
    """Expand placeholders in place; return the ROS 1 renames found, per file.

    The returned dict maps a remap file name to {ros2_name: ros1_name}, i.e.
    only the entries whose two sides ended up with different names.
    """
    remaps = {file_name: {} for file_name in REMAP_FILES.values()}
    for key in ENTRY_LISTS:
        entries = config.get(key)
        if not entries:
            continue
        resolved = []
        for entry in entries:
            if not keep(entry, use_sim_time):
                continue
            for name_key in NAME_KEYS:
                if name_key not in entry:
                    continue
                ros2_name = apply_namespace(entry[name_key], namespace, ros1_namespace)
                entry[name_key] = ros2_name
                ros1_name = entry.pop(ROS1_NAME_KEYS[name_key], None)
                if ros1_name is None:
                    continue
                ros1_name = apply_namespace(ros1_name, namespace, ros1_namespace)
                if ros1_name != ros2_name:
                    remaps[REMAP_FILES[name_key]][ros2_name] = ros1_name
            resolved.append(entry)
        config[key] = resolved
    return remaps


def write_remaps(remap_dir, remaps):
    """Write one "<ros2>:=<ros1>" token per line, one file per bridge process.

    Both files are always written, empty included: start.sh reads them
    unconditionally, and an absent file would abort it under `set -u`.
    """
    os.makedirs(remap_dir, exist_ok=True)
    for file_name, renames in remaps.items():
        path = os.path.join(remap_dir, file_name)
        with open(path, "w") as f:
            for ros2_name, ros1_name in renames.items():
                f.write(f"{ros2_name}:={ros1_name}\n")


def main():
    args = sys.argv[1:]
    remap_dir = None
    if "--remap-dir" in args:
        index = args.index("--remap-dir")
        try:
            remap_dir = args[index + 1]
        except IndexError:
            sys.exit("--remap-dir needs a directory")
        del args[index:index + 2]
    if len(args) != 1:
        print(
            f"usage: {sys.argv[0]} <config.yaml> [--remap-dir <dir>]",
            file=sys.stderr,
        )
        sys.exit(1)

    with open(args[0]) as f:
        config = yaml.safe_load(f) or {}

    namespace = os.environ.get("BRIDGE_NAMESPACE", "").strip().strip("/")
    # Falling back to BRIDGE_NAMESPACE keeps a config that uses {ros1_ns}
    # behaving exactly like one that does not: both sides resolve to the same
    # name, and no remap is emitted.
    ros1_namespace = os.environ.get("BRIDGE_ROS1_NAMESPACE", "").strip().strip("/")
    if not ros1_namespace:
        ros1_namespace = namespace
    use_sim_time = env_flag("BRIDGE_USE_SIM_TIME", True)
    master_uri = os.environ.get("ROS_MASTER_URI", "http://localhost:11311")
    print(
        f"namespace: {namespace or '<none>'}, "
        f"ros1 namespace: {ros1_namespace or '<none>'}, "
        f"use_sim_time: {use_sim_time}, master: {master_uri}"
    )

    remaps = resolve(config, namespace, ros1_namespace, use_sim_time)
    renamed = {
        ros2_name: ros1_name
        for renames in remaps.values()
        for ros2_name, ros1_name in renames.items()
    }
    if remap_dir:
        write_remaps(remap_dir, remaps)
    elif renamed:
        sys.exit(
            "config asks for different ROS 1 names but no --remap-dir was "
            "given, so the remaps would be silently dropped"
        )

    master = xmlrpc.client.ServerProxy(master_uri)

    while True:
        try:
            master.getSystemState(CALLER_ID)
            break
        except (ConnectionError, OSError):
            print(f"waiting for ROS 1 master at {master_uri}...")
            time.sleep(1)

    for key, value in config.items():
        code, message, _ignore = master.setParam(CALLER_ID, key, value)
        if code != 1:
            print(f"failed to set ROS 1 param '{key}': {message}", file=sys.stderr)
            sys.exit(1)
        print(f"loaded ROS 1 param '{key}' ({len(value)} entries)")
        for entry in value:
            name = next((entry[k] for k in NAME_KEYS if k in entry), None)
            if name:
                ros1_name = renamed.get(name)
                suffix = f"  (ROS 1: {ros1_name})" if ros1_name else ""
                print(f"    {name}{suffix}")


if __name__ == "__main__":
    main()
