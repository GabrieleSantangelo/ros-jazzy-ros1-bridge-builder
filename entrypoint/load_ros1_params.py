#!/usr/bin/env python3
# This image has no ROS 1 Python tooling (no `rosparam` CLI), only the
# compiled ros1_bridge C++ libraries. parameter_bridge reads its "topics" /
# "services_1_to_2" / "services_2_to_1" config from the ROS 1 parameter
# server at startup (not from a file), so something has to push the YAML
# there first. This does it with a raw XML-RPC call to the ROS 1 master,
# which is the parameter server too.
import os
import sys
import time
import xmlrpc.client

import yaml

CALLER_ID = "/bridge_config_loader"


def main():
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <config.yaml>", file=sys.stderr)
        sys.exit(1)

    with open(sys.argv[1]) as f:
        config = yaml.safe_load(f) or {}

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


if __name__ == "__main__":
    main()
