#!/usr/bin/env python3
"""
trigger_test.py — Validate LLaVA reasoning via rosbridge (same channel the
benchmark uses), bypassing the in-pod ros2 CLI daemon.

Connects to the dashboard rosbridge, publishes one prompt to /llava/trigger,
and listens for /llava/response and /llava/metrics_inference_ms.

Usage:
  python3 scripts/benchmark/trigger_test.py <host> <port>
  e.g.  python3 scripts/benchmark/trigger_test.py 158.42.104.15 31407
"""
import sys
import time
import roslibpy

HOST = sys.argv[1] if len(sys.argv) > 1 else "158.42.104.15"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 31407
WAIT_S = int(sys.argv[3]) if len(sys.argv) > 3 else 90

client = roslibpy.Ros(host=HOST, port=PORT)
print(f"[trigger_test] connecting to ws://{HOST}:{PORT} ...")
client.run()
print(f"[trigger_test] connected = {client.is_connected}")

got = {"response": None, "inf_ms": None, "t_resp": None}
t0 = time.time()

resp_topic = roslibpy.Topic(client, "/llava/response", "std_msgs/String")
inf_topic = roslibpy.Topic(client, "/llava/metrics_inference_ms", "std_msgs/Float32")


def on_response(msg):
    if got["response"] is None:
        got["response"] = msg.get("data", "")
        got["t_resp"] = time.time() - t0
        print(f"\n[trigger_test] LLaVA RESPONSE after {got['t_resp']:.1f}s:")
        print(f"  {got['response'][:300]}")


def on_inf(msg):
    if got["inf_ms"] is None:
        got["inf_ms"] = msg.get("data")
        print(f"[trigger_test] LLaVA inference time: {got['inf_ms']:.1f} ms")


resp_topic.subscribe(on_response)
inf_topic.subscribe(on_inf)

# Persistent publisher on /llava/trigger — advertise, then publish a few times
trig = roslibpy.Topic(client, "/llava/trigger", "std_msgs/String")
trig.advertise()
time.sleep(1.0)  # let advertise propagate
prompt = ("A factory robot sees a worker near a conveyor. "
          "Describe the scene and any safety concerns.")
for i in range(3):
    trig.publish(roslibpy.Message({"data": prompt}))
    print(f"[trigger_test] published trigger #{i+1}")
    time.sleep(2.0)

print(f"[trigger_test] waiting up to {WAIT_S}s for LLaVA ...")
while time.time() - t0 < WAIT_S:
    if got["response"] is not None and got["inf_ms"] is not None:
        break
    time.sleep(0.5)

print("\n========== RESULT ==========")
if got["response"] is not None:
    print(f"  LLaVA RESPONDED in {got['t_resp']:.1f}s  | inference={got['inf_ms']} ms")
    print("  => trigger via rosbridge WORKS. Safe to drive the benchmark this way.")
else:
    print("  NO response from LLaVA within timeout.")
    print("  => LLaVA did not infer. Check: is_processing stuck, topic QoS, or node error.")

try:
    trig.unadvertise()
    resp_topic.unsubscribe()
    inf_topic.unsubscribe()
except Exception:
    pass
client.terminate()
