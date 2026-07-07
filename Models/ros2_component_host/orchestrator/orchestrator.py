"""
FastAPI orchestrator for the Dynamic Module Loading pattern.

Replaces the previous subprocess.Popen approach (process spawning) with
ROS 2 service calls to /ComponentManager/{load_node, unload_node, list_nodes}.
This realizes the ROS 2 dynamic composition pattern from the
paper: components are LOADED INTO THE SAME PROCESS (the component
container running in a sibling container of the same pod), not spawned
as separate processes.

The component_container_isolated process exposes three services:
  /ComponentManager/load_node    composition_interfaces/srv/LoadNode
  /ComponentManager/unload_node  composition_interfaces/srv/UnloadNode
  /ComponentManager/list_nodes   composition_interfaces/srv/ListNodes

This orchestrator is a small rclpy node that:
  • Acts as a service client for those three services.
  • Exposes an HTTP API (FastAPI on port 5000) for the dashboard / external
    tooling to drive load/unload of components on demand.

The mapping between human-friendly module names and the rclpy_components
plugin names is defined in MODULE_REGISTRY below.
"""
import asyncio
import logging
import os
from contextlib import asynccontextmanager
from typing import Any, Optional

import rclpy
from rclpy.node import Node
from composition_interfaces.srv import LoadNode, UnloadNode, ListNodes
from rcl_interfaces.msg import Parameter, ParameterValue, ParameterType

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field
import uvicorn


logging.basicConfig(level=logging.INFO,
                    format='[%(asctime)s] [%(levelname)s] %(message)s')
log = logging.getLogger('orchestrator')


# ── Module registry ─────────────────────────────────────────────────────
# Maps the human-friendly name (used in HTTP requests) to the
# rclpy_components entry-point declared in each package's setup.py.
# The format is "<package_name>::<class_name>" — same as `ros2 component
# load` expects.
#
# When you add a new component, register it here and rebuild the
# ros2-component-host image with the new package available.
MODULE_REGISTRY = {
    'camera':  {'package': 'camera_driver_pkg',  'plugin': 'camera_driver_pkg::CameraDriver'},
    'yolo':    {'package': 'yolo_detector_pkg',  'plugin': 'yolo_detector_pkg::YoloDetector'},
    'llava':   {'package': 'llava_pkg',          'plugin': 'llava_pkg::LlavaNode'},
    'voxtral': {'package': 'voxtral_pkg',        'plugin': 'voxtral_pkg::VoxtralNode'},
}


# ── Parameter conversion helpers ────────────────────────────────────────
def _to_ros_parameter(name: str, value: Any) -> Parameter:
    """Convert a Python value to a rcl_interfaces.msg.Parameter.

    Used by /load to forward HTTP-supplied parameters into the LoadNode
    service request. Each plugin's __init__ will receive these as if they
    came from a launch file or a YAML param file.
    """
    p = Parameter()
    p.name = name
    pv = ParameterValue()
    if isinstance(value, bool):
        pv.type = ParameterType.PARAMETER_BOOL
        pv.bool_value = value
    elif isinstance(value, int):
        pv.type = ParameterType.PARAMETER_INTEGER
        pv.integer_value = value
    elif isinstance(value, float):
        pv.type = ParameterType.PARAMETER_DOUBLE
        pv.double_value = value
    elif isinstance(value, str):
        pv.type = ParameterType.PARAMETER_STRING
        pv.string_value = value
    elif isinstance(value, list):
        if not value:
            pv.type = ParameterType.PARAMETER_STRING_ARRAY
            pv.string_array_value = []
        elif all(isinstance(x, bool) for x in value):
            pv.type = ParameterType.PARAMETER_BOOL_ARRAY
            pv.bool_array_value = value
        elif all(isinstance(x, int) for x in value):
            pv.type = ParameterType.PARAMETER_INTEGER_ARRAY
            pv.integer_array_value = value
        elif all(isinstance(x, float) for x in value):
            pv.type = ParameterType.PARAMETER_DOUBLE_ARRAY
            pv.double_array_value = value
        elif all(isinstance(x, str) for x in value):
            pv.type = ParameterType.PARAMETER_STRING_ARRAY
            pv.string_array_value = value
        else:
            raise ValueError(f"Mixed-type array not supported for parameter '{name}'")
    else:
        raise ValueError(f"Unsupported parameter type {type(value).__name__} for '{name}'")
    p.value = pv
    return p


# ── ROS 2 client node ──────────────────────────────────────────────────
class ComponentManagerClient(Node):
    """rclpy node that calls the component_container's services."""

    SERVICE_TIMEOUT_S = 60.0   # LLaVA's __init__ loads ~13 GB → can take 15 s

    def __init__(self):
        super().__init__('component_manager_orchestrator')
        # Container name comes from env (defaults to ComponentManager). This
        # MUST match the chart's componentHost.containerName so service paths
        # resolve correctly.
        container_name = os.environ.get('COMPONENT_CONTAINER_NAME', 'ComponentManager')
        prefix = f'/{container_name}/_container'
        log.info(f'orchestrator using container prefix: {prefix}')
        self.cli_load   = self.create_client(LoadNode,   f'{prefix}/load_node')
        self.cli_unload = self.create_client(UnloadNode, f'{prefix}/unload_node')
        self.cli_list   = self.create_client(ListNodes,  f'{prefix}/list_nodes')
        # Tracks loaded plugin → unique_id (returned by LoadNode), needed for unload.
        self._loaded: dict[str, int] = {}

    async def _wait_service(self, client, name: str):
        """Wait until the component_container service is ready.
        Bumped from 30s → 90s grace because Jetson cold-start of
        component_container_isolated can take 45-60s for the rclpy
        plugin scanner + service registration.
        """
        for _ in range(180):  # 180 × 0.5s = 90s grace
            if client.service_is_ready():
                return
            await asyncio.sleep(0.5)
        raise HTTPException(503, f'Service {name} not available — is component_container running?')

    async def load(self, module: str, parameters: Optional[dict] = None) -> dict:
        if module not in MODULE_REGISTRY:
            raise HTTPException(404, f'Unknown module: {module}. '
                                       f'Known: {list(MODULE_REGISTRY.keys())}')
        if module in self._loaded:
            return {'module': module, 'status': 'already_loaded',
                    'unique_id': self._loaded[module]}

        await self._wait_service(self.cli_load, 'load_node')

        spec = MODULE_REGISTRY[module]
        req = LoadNode.Request()
        req.package_name = spec['package']
        req.plugin_name  = spec['plugin']
        req.node_name    = ''  # let the component pick its default
        req.node_namespace = ''
        # Forward optional parameters from HTTP body. They override the
        # plugin's declare_parameter() defaults at component __init__ time.
        if parameters:
            try:
                req.parameters = [_to_ros_parameter(k, v) for k, v in parameters.items()]
                log.info(f'[load] {module} parameters: {parameters}')
            except ValueError as e:
                raise HTTPException(400, f'Invalid parameter: {e}')

        log.info(f'[load] {module} → {spec["plugin"]}')
        future = self.cli_load.call_async(req)
        try:
            result = await asyncio.wait_for(asyncio.shield(_spin_until(self, future)),
                                            timeout=self.SERVICE_TIMEOUT_S)
        except asyncio.TimeoutError:
            raise HTTPException(504, f'LoadNode timed out after {self.SERVICE_TIMEOUT_S} s')

        if not result.success:
            raise HTTPException(500, f'LoadNode failed: {result.error_message}')

        self._loaded[module] = result.unique_id
        log.info(f'[load] {module} loaded with unique_id={result.unique_id}')
        return {'module': module, 'status': 'loaded',
                'unique_id': result.unique_id, 'full_node_name': result.full_node_name}

    async def unload(self, module: str) -> dict:
        if module not in self._loaded:
            raise HTTPException(404, f'Module {module} is not currently loaded')

        await self._wait_service(self.cli_unload, 'unload_node')

        unique_id = self._loaded[module]
        req = UnloadNode.Request()
        req.unique_id = unique_id

        log.info(f'[unload] {module} (unique_id={unique_id})')
        future = self.cli_unload.call_async(req)
        result = await _spin_until(self, future)

        if not result.success:
            raise HTTPException(500, f'UnloadNode failed: {result.error_message}')

        del self._loaded[module]
        log.info(f'[unload] {module} unloaded')
        return {'module': module, 'status': 'unloaded'}

    async def list_loaded(self) -> dict:
        await self._wait_service(self.cli_list, 'list_nodes')
        req = ListNodes.Request()
        future = self.cli_list.call_async(req)
        result = await _spin_until(self, future)
        return {
            'loaded': [
                {'unique_id': uid, 'full_node_name': name}
                for uid, name in zip(result.unique_ids, result.full_node_names)
            ],
            'tracked': self._loaded,
            'available': list(MODULE_REGISTRY.keys()),
        }


async def _spin_until(node: Node, future):
    """Spin the rclpy executor until the service future resolves."""
    while rclpy.ok() and not future.done():
        rclpy.spin_once(node, timeout_sec=0.1)
        await asyncio.sleep(0)
    return future.result()


# ── FastAPI app ─────────────────────────────────────────────────────────
class LoadRequest(BaseModel):
    module: str
    parameters: dict[str, Any] = Field(default_factory=dict)

class UnloadRequest(BaseModel):
    module: str


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Initialize rclpy + the manager client on startup."""
    rclpy.init()
    app.state.client = ComponentManagerClient()
    log.info(f'orchestrator ready. Registry: {list(MODULE_REGISTRY.keys())}')
    yield
    log.info('shutting down rclpy')
    app.state.client.destroy_node()
    rclpy.shutdown()


app = FastAPI(
    title='ROS 2 Dynamic Component Orchestrator',
    description='Loads/unloads rclpy_components into a running component_container',
    version='1.0.0',
    lifespan=lifespan,
)


@app.get('/health')
async def health():
    return {'ok': True, 'rclpy_ok': rclpy.ok()}


@app.get('/list')
async def list_components():
    return await app.state.client.list_loaded()


@app.post('/load')
async def load_component(req: LoadRequest):
    return await app.state.client.load(req.module, req.parameters)


@app.post('/unload')
async def unload_component(req: UnloadRequest):
    return await app.state.client.unload(req.module)


@app.get('/registry')
async def registry():
    """Inspect the static module registry."""
    return MODULE_REGISTRY


if __name__ == '__main__':
    port = int(os.environ.get('ORCHESTRATOR_PORT', '5000'))
    log.info(f'Starting FastAPI on 0.0.0.0:{port}')
    uvicorn.run(app, host='0.0.0.0', port=port, log_level='info')
