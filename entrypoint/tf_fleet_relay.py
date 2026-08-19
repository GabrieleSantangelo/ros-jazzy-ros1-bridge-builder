#!/usr/bin/env python3
# De-namespaces a robot's bridged TF into the shared ROS 2 fleet graph.
#
# The robot's ROS 1 side runs tf_remapper_cpp (see the planner repo,
# gbplanner/launch/anymal/tf_prefix.launch), which republishes /tf and
# /tf_static onto /<ns>/tf and /<ns>/tf_static with every frame id prefixed.
# parameter_bridge can only bridge a topic onto the *same* name on both sides,
# so those namespaced topics are what reaches ROS 2 -- but every tf2 listener,
# RViz 2 and Foxglove included, reads /tf and /tf_static and nothing else.
# This node closes that last hop.
#
# One instance per robot. Their frames no longer collide (that is what the
# prefixing bought), so all of them can publish into the same /tf.
#
# Direction note: this is the mirror of tf_static_repeater.py, which handles
# ROS 2 -> ROS 1 for the simulator. Here TF originates on the ROS 1 side, so
# the QoS problem is reversed -- see the comment on the static publisher below.
import os
import sys

import rclpy
from rclpy.node import Node
from rclpy.qos import DurabilityPolicy, HistoryPolicy, QoSProfile, ReliabilityPolicy
from tf2_msgs.msg import TFMessage


class TFFleetRelay(Node):
    def __init__(self, namespace):
        super().__init__(f'tf_fleet_relay_{namespace}')
        self._static = {}

        # parameter_bridge publishes on the ROS 2 side with volatile durability,
        # so both subscriptions have to be volatile to match it -- including the
        # static one, which is NOT transient_local at this point in the chain.
        sub_qos = QoSProfile(
            depth=100,
            history=HistoryPolicy.KEEP_LAST,
            reliability=ReliabilityPolicy.RELIABLE,
            durability=DurabilityPolicy.VOLATILE,
        )

        # /tf is volatile by convention; a straight pass-through is enough,
        # frames are already unique per robot.
        self._tf_pub = self.create_publisher(TFMessage, '/tf', sub_qos)
        self.create_subscription(
            TFMessage, f'/{namespace}/tf', self._on_tf, sub_qos)

        # /tf_static must be transient_local: every tf2_ros::TransformListener
        # subscribes to it with that durability, and a volatile publisher is
        # incompatible -- late joiners would silently receive nothing and every
        # lookup through a static link would fail with no error anywhere.
        # depth=1 because each publish carries the full accumulated set.
        static_pub_qos = QoSProfile(
            depth=1,
            history=HistoryPolicy.KEEP_LAST,
            reliability=ReliabilityPolicy.RELIABLE,
            durability=DurabilityPolicy.TRANSIENT_LOCAL,
        )
        self._static_pub = self.create_publisher(
            TFMessage, '/tf_static', static_pub_qos)

        # Subscribe to the incoming static topic TWICE, once per durability.
        # The ROS 1 side latches /<ns>/tf_static and publishes it once, so the
        # bridge forwards a single sample near startup. Which durability it
        # offers on the ROS 2 side decides how that sample can be caught:
        #   volatile         only a subscription matched BEFORE the publish
        #                    sees it - lose the DDS discovery race and the
        #                    robot's static frames are gone for the session,
        #                    with nothing logged anywhere.
        #   transient_local  a volatile subscription gets no history, so the
        #                    same race is lost just as silently.
        # Declaring both makes the node correct either way: exactly one
        # subscription matches, and _on_tf_static is idempotent, so a double
        # match would only re-merge the same transforms.
        for durability in (DurabilityPolicy.VOLATILE,
                           DurabilityPolicy.TRANSIENT_LOCAL):
            self.create_subscription(
                TFMessage, f'/{namespace}/tf_static', self._on_tf_static,
                QoSProfile(depth=100,
                           history=HistoryPolicy.KEEP_LAST,
                           reliability=ReliabilityPolicy.RELIABLE,
                           durability=durability))

        # Accumulate rather than forward: the bridge delivers the static set as
        # ordinary live messages, and a transient_local publisher only replays
        # its last sample to late joiners. Republishing the merged set keeps a
        # viewer that starts an hour in from missing the first frames.
        self.create_timer(1.0, self._republish_static)

    def _on_tf(self, msg):
        self._tf_pub.publish(msg)

    def _on_tf_static(self, msg):
        for t in msg.transforms:
            self._static[t.child_frame_id] = t
        self._static_pub.publish(
            TFMessage(transforms=list(self._static.values())))

    def _republish_static(self):
        if self._static:
            self._static_pub.publish(
                TFMessage(transforms=list(self._static.values())))


def main():
    namespace = os.environ.get('BRIDGE_NAMESPACE', '').strip().strip('/')
    if not namespace:
        sys.exit('tf_fleet_relay: BRIDGE_NAMESPACE is empty, nothing to relay')

    rclpy.init()
    node = TFFleetRelay(namespace)
    node.get_logger().info(
        f'relaying /{namespace}/tf -> /tf and /{namespace}/tf_static -> /tf_static')
    try:
        rclpy.spin(node)
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()
