import os
import sys
import time
import socket
import threading
import subprocess
from datetime import datetime

PROJECT_ROOT = os.path.dirname(os.path.abspath(__file__))
PYTHON_EXE = sys.executable
GODOT_EXE = os.path.join(PROJECT_ROOT, "tools", "godot", "Godot_v4.7.2-stable_win64_console.exe")
ARENA_DIR = os.path.join(PROJECT_ROOT, "arena")
SERVER_SCRIPT = os.path.join(PROJECT_ROOT, "brain_engine", "brain_server.py")
SERVER_PORT = 9999


def port_in_use(port):
    """True if something (e.g. a stale server) already holds the UDP port."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.bind(("127.0.0.1", port))
        return False
    except OSError:
        return True
    finally:
        s.close()


MAX_LOG_SIZE = 10 * 1024 * 1024  # 10 MB


def rotate_log_if_needed(log_path, max_size=MAX_LOG_SIZE):
    """Rotates log file to .old if it exceeds max_size."""
    if os.path.isfile(log_path):
        try:
            if os.path.getsize(log_path) > max_size:
                old_path = log_path + ".old"
                if os.path.isfile(old_path):
                    os.remove(old_path)
                os.replace(log_path, old_path)
        except OSError:
            pass


def pump_server_log(proc, log_path):
    """Drains the server's stdout to a log file. The pipe is NEVER read by
    the parent otherwise, so without this the server blocks forever once
    the OS pipe buffer fills (~4 KB) - typically wedged mid-print during
    a tournament_load, i.e. stuck at LOADING with live animations."""
    rotate_log_if_needed(log_path)
    with open(log_path, "a", encoding="utf-8") as f:
        f.write(f"\n===== server launch {datetime.now().isoformat(timespec='seconds')} =====\n")
        f.flush()
        for line in proc.stdout:
            f.write(line)
            f.flush()


def main():
    import argparse
    ap = argparse.ArgumentParser(description="Battle Fly Arena launcher")
    ap.add_argument("--direct", action="store_true",
                    help="Boot straight into a free battle (skip the vault menu).")
    args = ap.parse_args()

    print("=" * 65)
    print("      LAUNCHING BATTLE FLY ARENA - WHOLE CONNECTOME SIMULATION")
    print("=" * 65)
    print(f"[*] Python: {PYTHON_EXE}")
    print(f"[*] Godot:  {GODOT_EXE}")
    print(f"[*] Arena:  {ARENA_DIR}")
    print(f"[*] Mode:   {'direct battle' if args.direct else 'vault menu'}")

    # 1. Start the Dual-Brain Connectome Server
    print("\n[1/2] Starting Connectome Neuro-Server (MaleCNS v1.0)...")
    if port_in_use(SERVER_PORT):
        print(f"[FATAL] UDP port {SERVER_PORT} is already held by another process.")
        print("        A stale server (or a second game instance) is still running:")
        print("        close it first, otherwise this game would silently talk to")
        print("        the WRONG server (stolen replies, phantom stalls). Aborting.")
        sys.exit(2)
    env = dict(os.environ)
    env["FO_PY"] = PYTHON_EXE
    env["FO_VAULT_CLI"] = os.path.join(PROJECT_ROOT, "brain_engine", "vault_cli.py")
    if args.direct:
        env["FO_DIRECT"] = "1"
    server_log = os.path.join(PROJECT_ROOT, "server_log.txt")
    server_proc = subprocess.Popen(
        [PYTHON_EXE, "-u", SERVER_SCRIPT],
        cwd=os.path.join(PROJECT_ROOT, "brain_engine"),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
        env=env
    )
    log_thread = threading.Thread(target=pump_server_log,
                                  args=(server_proc, server_log), daemon=True)
    log_thread.start()
    print(f"[*] Server log: {server_log}")

    # Wait for server ready message
    time.sleep(2.5)

    # 2. Launch Godot 4 (main scene = vault menu, unless --direct)
    print("[2/2] Launching Godot 4...")
    try:
        godot_proc = subprocess.run(
            [GODOT_EXE, "--path", ARENA_DIR],
            cwd=PROJECT_ROOT,
            env=env
        )
    finally:
        # Exit-code honesty: a nonzero Godot return means the game
        # crashed (or was killed) rather than quit cleanly - say so,
        # so the next mid-event vanishing window is diagnosable here
        # instead of reading as a server shutdown.
        code = godot_proc.returncode if "godot_proc" in dir() else "?"
        if code == 0:
            print("\n[*] Godot exited clean (code 0).")
        else:
            print(f"\n[*] Godot is gone with exit code {code} - "
                  "CRASH/KILL suspected, not a clean quit.")
        print("[*] Shutting down Connectome Server...")
        server_proc.terminate()
        try:
            server_proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            server_proc.kill()
        print("[*] Shutdown complete. All genomes preserved.")


if __name__ == "__main__":
    main()
