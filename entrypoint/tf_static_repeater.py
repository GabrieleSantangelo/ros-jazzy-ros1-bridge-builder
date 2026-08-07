#!/usr/bin/env python3
# Works around ros1_bridge subscribing to /tf_static with volatile QoS, which
# never receives the one-shot transient_local publish from static tf sources
# (robot_state_publisher, static_transform_publisher, ...). This node listens
# with the correct transient_local QoS, accumulates every frame ever seen,
# and periodically republishes the merged set as a plain live message so the
# bridge's volatile subscriber picks it up like any other continuous topic.
import rclpy
from rclpy.node import Node
from rclpy.qos import DurabilityPolicy, HistoryPolicy, QoSProfile, ReliabilityPolicy
from tf2_msgs.msg import TFMessage


class TFStaticRepeater(Node):
    def __init__(self):
        super().__init__('tf_static_repeater')
        self._transforms = {}

        sub_qos = QoSProfile(
            depth=100,
            history=HistoryPolicy.KEEP_LAST,
            reliability=ReliabilityPolicy.RELIABLE,
            durability=DurabilityPolicy.TRANSIENT_LOCAL,
        )
        self.create_subscription(TFMessage, '/tf_static', self._on_tf_static, sub_qos)

        pub_qos = QoSProfile(depth=100, history=HistoryPolicy.KEEP_LAST)
        self._pub = self.create_publisher(TFMessage, '/tf_static', pub_qos)

        self.create_timer(1.0, self._republish)

    def _on_tf_static(self, msg):
        for t in msg.transforms:
            self._transforms[t.child_frame_id] = t

    def _republish(self):
        if self._transforms:
            self._pub.publish(TFMessage(transforms=list(self._transforms.values())))


def main():
    rclpy.init()
    node = TFStaticRepeater()
    try:
        rclpy.spin(node)
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()
