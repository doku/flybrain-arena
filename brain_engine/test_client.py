import socket
import json
import time

def test_client():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(2.0)
    server_addr = ("127.0.0.1", 9999)

    test_packet = {
        "type": "step",
        "alpha": {
            "pheromone_conc_left": 0.8,
            "pheromone_conc_right": 0.1,
            "visual_target_azimuth": -20.0,
            "visual_target_elevation": 5.0,
            "visual_target_visible": True,
            "visual_looming_rate": 0.1
        },
        "beta": {
            "pheromone_conc_left": 0.05,
            "pheromone_conc_right": 0.7,
            "visual_target_azimuth": 35.0,
            "visual_target_elevation": -2.0,
            "visual_target_visible": True,
            "visual_looming_rate": 0.0
        }
    }

    print("[Client] Sending test sensory step packet...")
    t0 = time.time()
    sock.sendto(json.dumps(test_packet).encode("utf-8"), server_addr)

    try:
        data, _ = sock.recvfrom(65535)
        dt_ms = (time.time() - t0) * 1000.0
        res = json.loads(data.decode("utf-8"))
        print(f"[Client] Received response in {dt_ms:.2f} ms:")
        print(json.dumps(res, indent=2))
    except socket.timeout:
        print("[Client Error] Socket timed out waiting for server!")

if __name__ == "__main__":
    test_client()
