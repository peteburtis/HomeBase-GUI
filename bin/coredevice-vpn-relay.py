#!/usr/bin/env python3

"""Relay CoreDevice's local Bonjour endpoint to an iPhone VPN address."""

from __future__ import annotations

import argparse
import os
import resource
import selectors
import signal
import socket
import subprocess
import sys
import threading
import time
from pathlib import Path


COREDEVICE_SERVICE = "_remotepairing._tcp"
running = True


def log(message: str) -> None:
    print(message, flush=True)


def stop(_signum: int, _frame: object) -> None:
    global running
    running = False


def load_metadata(path: Path) -> tuple[str, int, list[str]]:
    instance = ""
    port = 0
    txt_records: list[str] = []

    for raw_line in path.read_text(encoding="utf-8").splitlines():
        if raw_line.startswith("instance="):
            instance = raw_line.removeprefix("instance=")
        elif raw_line.startswith("port="):
            port = int(raw_line.removeprefix("port="))
        elif raw_line.startswith("txt="):
            txt_records.append(raw_line.removeprefix("txt="))

    if not instance or not 0 < port < 65536 or not txt_records:
        raise ValueError(f"invalid CoreDevice metadata in {path}")
    return instance, port, txt_records


def parse_port_range(value: str) -> range:
    start_text, separator, end_text = value.partition("-")
    if not separator:
        raise ValueError("port range must use START-END syntax")
    start = int(start_text)
    end = int(end_text)
    if not 0 < start <= end < 65536:
        raise ValueError("port range must be between 1 and 65535")
    return range(start, end + 1)


def raise_file_limit(required: int) -> None:
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    desired = min(max(soft, required), hard)
    if desired > soft:
        resource.setrlimit(resource.RLIMIT_NOFILE, (desired, hard))


def relay_tcp_connection(
    client: socket.socket, remote_host: str, remote_port: int
) -> None:
    remote: socket.socket | None = None
    connection_selector: selectors.BaseSelector | None = None
    try:
        remote = socket.create_connection((remote_host, remote_port), timeout=10)
        client.setblocking(True)
        remote.setblocking(True)
        connection_selector = selectors.DefaultSelector()
        connection_selector.register(client, selectors.EVENT_READ)
        connection_selector.register(remote, selectors.EVENT_READ)

        while running:
            for key, _events in connection_selector.select(timeout=1):
                source: socket.socket = key.fileobj
                data = source.recv(65536)
                if not data:
                    return
                destination = remote if source is client else client
                destination.sendall(data)
    except OSError as error:
        log(f"TCP relay {remote_port} ended: {error}")
    finally:
        if connection_selector is not None:
            connection_selector.close()
        client.close()
        if remote is not None:
            remote.close()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--interface", required=True)
    parser.add_argument("--listen-host", required=True)
    parser.add_argument("--remote-host", required=True)
    parser.add_argument("--proxy-hostname", required=True)
    parser.add_argument("--metadata-file", type=Path, required=True)
    parser.add_argument("--listen-control-port", type=int, default=49151)
    parser.add_argument("--dynamic-ports", default="55000-59000")
    parser.add_argument("--ready-file", type=Path, required=True)
    arguments = parser.parse_args()

    instance, remote_control_port, txt_records = load_metadata(arguments.metadata_file)
    local_control_port = arguments.listen_control_port
    if not 0 < local_control_port < 65536:
        raise ValueError("local control port must be between 1 and 65535")
    dynamic_ports = parse_port_range(arguments.dynamic_ports)
    raise_file_limit((len(dynamic_ports) * 2) + 64)

    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)

    selector = selectors.DefaultSelector()
    sockets: list[socket.socket] = []
    local_udp_peers: dict[int, tuple[str, int]] = {}
    observed_udp_ports: set[int] = set()

    def bind_udp(local_port: int, remote_port: int, required: bool) -> None:
        udp_socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        udp_socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            udp_socket.bind((arguments.listen_host, local_port))
        except OSError as error:
            udp_socket.close()
            if required:
                raise OSError(
                    f"cannot bind required UDP relay "
                    f"{arguments.listen_host}:{local_port}: {error}"
                ) from error
            log(f"Skipping unavailable UDP relay port {local_port}: {error}")
            return
        udp_socket.setblocking(False)
        selector.register(
            udp_socket,
            selectors.EVENT_READ,
            ("udp", local_port, remote_port),
        )
        sockets.append(udp_socket)

    def bind_tcp(local_port: int, remote_port: int, required: bool) -> None:
        tcp_listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        tcp_listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            tcp_listener.bind((arguments.listen_host, local_port))
        except OSError as error:
            tcp_listener.close()
            if required:
                raise OSError(
                    f"cannot bind required TCP relay "
                    f"{arguments.listen_host}:{local_port}: {error}"
                ) from error
            log(f"Skipping unavailable TCP relay port {local_port}: {error}")
            return
        tcp_listener.listen()
        tcp_listener.setblocking(False)
        selector.register(
            tcp_listener,
            selectors.EVENT_READ,
            ("tcp", local_port, remote_port),
        )
        sockets.append(tcp_listener)

    bind_tcp(local_control_port, remote_control_port, required=True)
    bind_udp(local_control_port, remote_control_port, required=True)
    for dynamic_port in dynamic_ports:
        if dynamic_port != local_control_port:
            bind_tcp(dynamic_port, dynamic_port, required=False)
            bind_udp(dynamic_port, dynamic_port, required=False)

    dns_command = [
        "/usr/bin/dns-sd",
        "-i",
        arguments.interface,
        "-P",
        instance,
        COREDEVICE_SERVICE,
        "local.",
        str(local_control_port),
        arguments.proxy_hostname,
        arguments.listen_host,
        *txt_records,
    ]
    dns_process = subprocess.Popen(dns_command)

    try:
        time.sleep(1)
        if dns_process.poll() is not None:
            raise RuntimeError(
                f"dns-sd registration exited with status {dns_process.returncode}"
            )

        arguments.ready_file.write_text(f"{os.getpid()}\n", encoding="utf-8")
        log(
            f"Relaying {instance} from "
            f"{arguments.listen_host}:{local_control_port} to "
            f"{arguments.remote_host}:{remote_control_port}; "
            f"dynamic TCP/UDP {arguments.dynamic_ports}"
        )

        while running and dns_process.poll() is None:
            for key, _events in selector.select(timeout=1):
                kind, local_port, remote_port = key.data
                relay_socket: socket.socket = key.fileobj

                if kind == "tcp":
                    client, client_address = relay_socket.accept()
                    if client_address[0] not in {
                        arguments.listen_host,
                        "127.0.0.1",
                    }:
                        client.close()
                        continue
                    log(
                        f"Accepted TCP relay {local_port}->{remote_port} "
                        f"from {client_address[0]}:{client_address[1]}"
                    )
                    threading.Thread(
                        target=relay_tcp_connection,
                        args=(client, arguments.remote_host, remote_port),
                        daemon=True,
                    ).start()
                    continue

                data, sender = relay_socket.recvfrom(65536)
                if sender == (arguments.remote_host, remote_port):
                    local_peer = local_udp_peers.get(local_port)
                    if local_peer is not None:
                        relay_socket.sendto(data, local_peer)
                elif sender[0] in {arguments.listen_host, "127.0.0.1"}:
                    local_udp_peers[local_port] = sender
                    if local_port not in observed_udp_ports:
                        observed_udp_ports.add(local_port)
                        log(f"Relaying UDP port {local_port}->{remote_port}")
                    relay_socket.sendto(
                        data,
                        (arguments.remote_host, remote_port),
                    )

        if running:
            raise RuntimeError(
                f"dns-sd registration exited with status {dns_process.returncode}"
            )
    finally:
        arguments.ready_file.unlink(missing_ok=True)
        if dns_process.poll() is None:
            dns_process.terminate()
            try:
                dns_process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                dns_process.kill()
        for relay_socket in sockets:
            relay_socket.close()
        selector.close()

    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr, flush=True)
        raise SystemExit(1)
