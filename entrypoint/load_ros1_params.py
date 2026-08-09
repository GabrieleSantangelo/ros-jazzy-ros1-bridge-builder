#!/usr/bin/env python3
# This image has no ROS 1 Python tooling (no `rosparam` CLI), only the
# compiled ros1_bridge C++ libraries. parameter_bridge reads its "topics" /
# "services_1_to_2" / "services_2_to_1" config from the ROS 1 parameter
# server at startup (not from a file), so something has to push the YAML
# there first. This does it with a raw XML-RPC call to the ROS 1 master,
# which is the parameter server too.
#
# Two knobs come in as environment variables (set from the Makefile, see
# `make run NAMESPACE=... USE_SIM_TIME=...`), so one YAML can serve several
# robots without being edited:
#
#   BRIDGE_NAMESPACE   -- replaces the "{ns}" placeholder in every "topic"
#                         and "service" name. Empty means no namespace, and
#                         the leftover slash collapses: "/{ns}/odom" -> "/odom".
#   BRIDGE_USE_SIM_TIME -- when false, entries marked "when: sim_time" (i.e.
#                         /clock) are dropped instead of being bridged.
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

# Per-entry keys naming a ROS resource, i.e. the ones {ns} applies to.
NAME_KEYS = ("topic", "service")

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


def apply_namespace(name, namespace):
    """Expand {ns} and clean up the slashes an empty namespace leaves behind."""
    expanded = name.replace("{ns}", namespace)
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


def resolve(config, namespace, use_sim_time):
    for key in ENTRY_LISTS:
        entries = config.get(key)
        if not entries:
            continue
        resolved = []
        for entry in entries:
            if not keep(entry, use_sim_time):
                continue
            for name_key in NAME_KEYS:
                if name_key in entry:
                    entry[name_key] = apply_namespace(entry[name_key], namespace)
            resolved.append(entry)
        config[key] = resolved
    return config


def main():
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <config.yaml>", file=sys.stderr)
        sys.exit(1)

    with open(sys.argv[1]) as f:
        config = yaml.safe_load(f) or {}

    namespace = os.environ.get("BRIDGE_NAMESPACE", "").strip().strip("/")
    use_sim_time = env_flag("BRIDGE_USE_SIM_TIME", True)
    print(f"namespace: {namespace or '<none>'}, use_sim_time: {use_sim_time}")

    config = resolve(config, namespace, use_sim_time)

    master_uri = os.environ.get("ROS_MASTER_URI", "http://localhost:11311")
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
                print(f"    {name}")


if __name__ == "__main__":
    main()
