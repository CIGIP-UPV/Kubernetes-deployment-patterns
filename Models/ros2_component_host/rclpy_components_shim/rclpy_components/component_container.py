#!/usr/bin/env python3
"""Minimal component_container for rclpy plugins (Humble shim).

This is a local replacement for the upstream ros2/rclpy_components
component_container_isolated. It hosts rclpy-based plugins inside its
own process and exposes the standard ROS 2 services LoadNode,
UnloadNode and ListNodes so an external orchestrator (or `ros2 component`
CLI) can drive lifecycle on demand.

Plugin discovery is via setuptools entry_points group 'rclpy_components'.
Each registered entry must point at a class that subclasses rclpy.Node.

Service paths (matching the upstream container_isolated convention):

    /<container_name>/_container/load_node     composition_interfaces/srv/LoadNode
    /<container_name>/_container/unload_node   composition_interfaces/srv/UnloadNode
    /<container_name>/_container/list_nodes    composition_interfaces/srv/ListNodes

The orchestrator (Models/ros2_component_host/orchestrator/orchestrator.py)
calls these services with a per-load parameters list. Each parameter is
applied to the loaded node before its first spin.
"""
import argparse
import importlib
import logging
import sys
import threading
import traceback
from typing import Any, Dict, Optional

import rclpy
from rclpy.executors import MultiThreadedExecutor
from rclpy.node import Node
from rclpy.parameter import Parameter as RclPyParameter
from composition_interfaces.srv import LoadNode, UnloadNode, ListNodes

# pkg_resources is the legacy (still works in Humble's setuptools) lookup
# for setuptools entry_points. We use it because it does not require a
# specific setuptools version and is robust across ament_python builds.
try:
    from pkg_resources import iter_entry_points
except ImportError:                                 # pragma: no cover
    # importlib.metadata fallback for newer Python (Humble ships 3.10).
    from importlib.metadata import entry_points as _ep_v2

    def iter_entry_points(group):
        eps = _ep_v2().get(group, [])
        return list(eps)


log = logging.getLogger('component_container')


def _ros_param_to_rclpy(p) -> RclPyParameter:
    """Convert a rcl_interfaces.msg.Parameter to a rclpy.parameter.Parameter."""
    pv = p.value
    # ParameterType: 1=BOOL 2=INT 3=DOUBLE 4=STRING 5=BYTE_ARRAY 6=BOOL_ARRAY
    #                7=INT_ARRAY 8=DOUBLE_ARRAY 9=STRING_ARRAY
    if   pv.type == 1: return RclPyParameter(p.name, RclPyParameter.Type.BOOL,         pv.bool_value)
    elif pv.type == 2: return RclPyParameter(p.name, RclPyParameter.Type.INTEGER,      pv.integer_value)
    elif pv.type == 3: return RclPyParameter(p.name, RclPyParameter.Type.DOUBLE,       pv.double_value)
    elif pv.type == 4: return RclPyParameter(p.name, RclPyParameter.Type.STRING,       pv.string_value)
    elif pv.type == 6: return RclPyParameter(p.name, RclPyParameter.Type.BOOL_ARRAY,   list(pv.bool_array_value))
    elif pv.type == 7: return RclPyParameter(p.name, RclPyParameter.Type.INTEGER_ARRAY, list(pv.integer_array_value))
    elif pv.type == 8: return RclPyParameter(p.name, RclPyParameter.Type.DOUBLE_ARRAY, list(pv.double_array_value))
    elif pv.type == 9: return RclPyParameter(p.name, RclPyParameter.Type.STRING_ARRAY, list(pv.string_array_value))
    else:
        raise ValueError(f'Unsupported ParameterType={pv.type} for "{p.name}"')


def _resolve_plugin_class(plugin_name: str):
    """Look up a class by its rclpy_components entry_point name.

    plugin_name format: "package_name::ClassName" (upstream convention).

    We accept both 'pkg::Class' and the equivalent setuptools target
    'pkg.module:Class' to be lenient.
    """
    for ep in iter_entry_points('rclpy_components'):
        # Entry-point names registered by our packages match plugin_name.
        if ep.name == plugin_name:
            return ep.load()
    raise LookupError(
        f'Plugin "{plugin_name}" not found in rclpy_components entry_points. '
        f'Available: {[e.name for e in iter_entry_points("rclpy_components")]}'
    )


class ComponentContainer(Node):
    """ROS 2 node that hosts dynamically loaded rclpy components."""

    def __init__(self, name: str = 'ComponentManager'):
        super().__init__(name)
        prefix = f'{name}/_container'
        # Loaded components: unique_id → (plugin_name, full_node_name, instance)
        self._loaded: Dict[int, tuple] = {}
        self._next_id = 1
        self._lock = threading.Lock()
        self._executor: Optional[MultiThreadedExecutor] = None

        self._srv_load   = self.create_service(LoadNode,   f'{prefix}/load_node',   self._cb_load)
        self._srv_unload = self.create_service(UnloadNode, f'{prefix}/unload_node', self._cb_unload)
        self._srv_list   = self.create_service(ListNodes,  f'{prefix}/list_nodes',  self._cb_list)

        self.get_logger().info(
            f'Component container "{name}" ready. '
            f'Services exposed under {prefix}/. '
            f'Discoverable plugins: '
            f'{[e.name for e in iter_entry_points("rclpy_components")]}'
        )

    def attach_executor(self, executor: MultiThreadedExecutor):
        self._executor = executor

    # ── Callbacks ────────────────────────────────────────────────────
    def _cb_load(self, request, response):
        try:
            plugin_name = request.plugin_name
            self.get_logger().info(f'[load] plugin="{plugin_name}"')
            plugin_cls = _resolve_plugin_class(plugin_name)

            # Build initial parameters from request.parameters[].
            init_params = []
            for p in request.parameters:
                init_params.append(_ros_param_to_rclpy(p))

            node_name = request.node_name or None  # let plugin choose
            namespace = request.node_namespace or ''

            # CRITICAL: parameters must be applied BEFORE the plugin's __init__
            # runs, because most plugins do `self.declare_parameter('device',
            # '/dev/video0')` followed IMMEDIATELY by `self.get_parameter(...)`
            # in __init__. If we wait until after instantiation to set them,
            # the plugin has already opened the wrong /dev or constructed an
            # incorrect model with default values.
            #
            # The clean way: rclpy.node.Node.__init__ accepts a
            # `parameter_overrides=` kwarg that wins over declare_parameter
            # defaults. Plugins call `super().__init__('camera_driver')` with
            # no overrides. We monkey-patch Node.__init__ for the duration of
            # plugin_cls() instantiation so any super().__init__() in the
            # plugin's chain receives our overrides automatically.
            #
            # This is single-threaded by design (LoadNode service is serialized
            # by the executor's reentrant_callback_group=None default), so the
            # patch/unpatch around plugin_cls() is safe.
            import rclpy.node
            _orig_node_init = rclpy.node.Node.__init__

            def _patched_node_init(self, *args, **kwargs):
                # Only inject if the caller didn't already pass overrides.
                if init_params and 'parameter_overrides' not in kwargs:
                    kwargs['parameter_overrides'] = init_params
                return _orig_node_init(self, *args, **kwargs)

            rclpy.node.Node.__init__ = _patched_node_init
            try:
                # Some plugins accept name/namespace; try with kwargs first.
                try:
                    if node_name and 'name' in plugin_cls.__init__.__code__.co_varnames:
                        instance = plugin_cls(name=node_name, namespace=namespace)
                    else:
                        instance = plugin_cls()
                except TypeError:
                    instance = plugin_cls()
            finally:
                # Always restore — even if plugin __init__ raised.
                rclpy.node.Node.__init__ = _orig_node_init

            # Belt-and-suspenders: also set the parameters on the live node
            # AFTER instantiation. Useful for plugins that re-read params
            # later (timers, subscriber callbacks). Failures here are
            # warnings only because parameter_overrides above already did
            # the heavy lifting at construction time.
            if init_params:
                try:
                    instance.set_parameters(init_params)
                except Exception as e:
                    self.get_logger().warn(
                        f'[load] some parameters could not be re-set on {plugin_name}: {e}'
                    )

            # Add to executor so its callbacks run.
            if self._executor:
                self._executor.add_node(instance)

            with self._lock:
                uid = self._next_id
                self._next_id += 1
                self._loaded[uid] = (plugin_name, instance.get_name(), instance)

            response.success = True
            response.error_message = ''
            response.full_node_name = instance.get_name()
            response.unique_id = uid
            self.get_logger().info(
                f'[load] OK uid={uid} full_node_name={instance.get_name()}'
            )
        except Exception as e:                       # pragma: no cover
            tb = traceback.format_exc()
            self.get_logger().error(f'[load] FAILED: {e}\n{tb}')
            response.success = False
            response.error_message = f'{e}'
            response.full_node_name = ''
            response.unique_id = 0
        return response

    def _cb_unload(self, request, response):
        with self._lock:
            entry = self._loaded.pop(request.unique_id, None)
        if entry is None:
            response.success = False
            response.error_message = f'unique_id={request.unique_id} not loaded'
            return response
        plugin_name, full_node_name, instance = entry
        try:
            if self._executor:
                self._executor.remove_node(instance)
            instance.destroy_node()
            response.success = True
            response.error_message = ''
            self.get_logger().info(f'[unload] OK uid={request.unique_id} ({full_node_name})')
        except Exception as e:                       # pragma: no cover
            response.success = False
            response.error_message = f'{e}'
            self.get_logger().error(f'[unload] FAILED: {e}')
        return response

    def _cb_list(self, request, response):
        with self._lock:
            items = list(self._loaded.items())
        response.unique_ids = [uid for uid, _ in items]
        response.full_node_names = [name for _, (_, name, _) in items]
        return response


def main(argv=None):
    """Entry point. Mimics ros2 run rclpy_components component_container_isolated."""
    if argv is None:
        argv = sys.argv

    # The `ros2 run rclpy_components ... --ros-args -r __node:=Foo` rewrite
    # is consumed by rclpy.init(). The leftover args we don't need.
    parser = argparse.ArgumentParser(
        description='Minimal rclpy_components container_isolated (Humble shim).')
    parser.add_argument('--name', default='ComponentManager',
                        help='Container node name. Overridden by --ros-args -r __node:=...')
    # Parse known to be tolerant of --ros-args remappings.
    known, _ = parser.parse_known_args(argv[1:])

    rclpy.init(args=argv)

    # Allow the -r __node:= override from ROS args.
    container_name = known.name
    # rclpy.init already strips --ros-args; but the remap of __node is
    # already applied to the NEW Node when it's instantiated with the
    # default name. We pass our parsed name and let rclpy apply remaps.
    container = ComponentContainer(name=container_name)
    executor = MultiThreadedExecutor(num_threads=4)
    container.attach_executor(executor)
    executor.add_node(container)

    log.info(f'spin: container={container.get_name()}')
    try:
        executor.spin()
    except KeyboardInterrupt:                        # pragma: no cover
        pass
    finally:
        container.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()
