#!/usr/bin/env python3
"""A/B: DSpark drafter vs n-gram, w dwoch rozmiarach tieru RAM.

Ramię = (RAM tier GB, dspark on/off). Wszystko przez Maya (obraz maya-gfx906:0.2-mxfp4.1),
ten sam pack IQ2_XXS, jedna MI50, ctx 8192, temperatura 0.

Uzycie: ab_dspark.py <ram_gb> <on|off> <tag>
Wynik: dokleja wiersze do results.csv w katalogu skryptu + zapisuje log ramienia.
"""
import json
import os
import re
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
IMAGE = "xxdoman/maya-gfx906:0.2-mxfp4.1"
NAME = "maya-ab"
DSPARK = "/models/gguf/DSpark-drafter-Q2K-Q8-MarkovQ8-0731.gguf"

PROMPTS = [
    ("p1_diesel",
     "Explain how a turbocharger on a diesel engine works and why it improves fuel efficiency."),
    ("p2_novel",
     "Write a short review of a fictional 1970s science fiction novel about a generation ship whose crew has forgotten the mission."),
    ("p3_lighthouse",
     "Describe the daily routine of a lighthouse keeper on a remote island in winter."),
]


def sh(cmd, **kw):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True, **kw)


def vram_used_mib():
    out = sh("rocm-smi -d 0 --showmeminfo vram --json").stdout
    try:
        for card in json.loads(out).values():
            return int(card["VRAM Total Used Memory (B)"]) / 2**20
    except Exception:
        pass
    out = sh("rocm-smi -d 0 --showmeminfo vram").stdout
    m = re.search(r"Used Memory \(B\): (\d+)", out)
    return int(m.group(1)) / 2**20 if m else -1


def read_cfg():
    out = sh(f"docker run --rm -v maya-data:/data --entrypoint cat {IMAGE} /data/maya/strata-dsv4.json")
    return json.loads(out.stdout)


def write_cfg(cfg):
    payload = json.dumps(cfg, indent=2) + "\n"
    p = os.path.join(HERE, "_cfg.json")
    with open(p, "w") as f:
        f.write(payload)
    sh(f"docker run --rm -v maya-data:/data -v {HERE}:/ab --entrypoint cp {IMAGE} /ab/_cfg.json /data/maya/strata-dsv4.json")


def set_arm(ram_gb, on, experts="64"):
    cfg = read_cfg()
    env = cfg.setdefault("env", {})
    env["STRATA_GLM_RAM_GB"] = str(ram_gb)
    env["STRATA_GLM_TIMING"] = "1"
    env["STRATA_GLM_RAM_THP"] = "0"
    args = [a for a in cfg.get("args", []) if a != "--spec"]
    # --spec usuwamy z pary wartosci, jesli byla
    cleaned, skip = [], False
    for a in cfg.get("args", []):
        if skip:
            skip = False
            continue
        if a == "--spec":
            skip = True
            continue
        cleaned.append(a)
    cleaned += ["--spec", "5" if on else "4"]
    cfg["args"] = cleaned
    if on:
        env["STRATA_DS4_DSPARK"] = DSPARK
        env["STRATA_DS4_DSPARK_EXPERTS"] = experts
    else:
        env.pop("STRATA_DS4_DSPARK", None)
        env.pop("STRATA_DS4_DSPARK_EXPERTS", None)
    write_cfg(cfg)
    print("config:", json.dumps(cfg["args"]), json.dumps({k: v for k, v in env.items() if k.startswith("STRATA_")}))


def wait_vram_zero(limit=180):
    t0 = time.time()
    while time.time() - t0 < limit:
        v = vram_used_mib()
        if v < 900:  # karta bez monitora: ~0 po zwolnieniu
            return v
        time.sleep(5)
    return vram_used_mib()


def start():
    sh(f"docker rm -f {NAME}")
    wait_vram_zero()
    # log silnika jest dopisywany miedzy sesjami — bez rotacji "gotowy" lapie stara linie
    sh(f"docker run --rm -v maya-data:/data --entrypoint sh {IMAGE} -c "
       "'cd /data/maya/logs && [ -f abyss-server.log ] && mv -f abyss-server.log abyss-server.log.prev; true'")
    cmd = (
        f"docker run -d --name {NAME} "
        "--device /dev/kfd --device /dev/dri --group-add video --group-add render "
        "--ulimit memlock=-1 -p 8092:8092 -v /home/models:/models -v maya-data:/data "
        f"{IMAGE}"
    )
    r = sh(cmd)
    if r.returncode != 0:
        raise SystemExit("docker run: " + r.stderr)


def wait_ready(limit=900):
    t0 = time.time()
    while time.time() - t0 < limit:
        if sh(f"docker inspect -f '{{{{.State.Running}}}}' {NAME}").stdout.strip() != "true":
            raise SystemExit("kontener padl:\n" + sh(f"docker logs --tail 40 {NAME}").stdout)
        log = sh(f"docker exec {NAME} cat /data/maya/logs/abyss-server.log").stdout
        if "glm5-next serve" in log:
            probe = sh(f"curl -s -m 5 -o /dev/null -w '%{{http_code}}' http://127.0.0.1:8092/").stdout.strip()
            if probe not in ("000", ""):
                return time.time() - t0
        time.sleep(10)
    raise SystemExit("timeout na start silnika")


def ask(prompt, n=120):
    body = json.dumps({
        "model": "deepseek-v4-flash-0731",
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": n,
        "temperature": 0,
    })
    for attempt in range(3):
        r = sh(f"curl -s -m 900 -X POST http://127.0.0.1:8092/v1/chat/completions "
               f"-H 'Content-Type: application/json' -d '{body}'")
        try:
            got = json.loads(r.stdout)
            if got.get("choices"):
                return got
        except Exception:
            pass
        print(f"  request nieudany (proba {attempt + 1}): {r.stdout[:200]}")
        time.sleep(10)
    raise SystemExit("silnik nie odpowiada na /v1/chat/completions")


def last_stat():
    log = sh(f"docker exec {NAME} cat /data/maya/logs/abyss-server.log").stdout
    stat = [l for l in log.splitlines() if l.startswith("glm stat:")]
    dsp = [l for l in log.splitlines() if l.startswith("dspark:") or l.startswith("ds4 dspark:")]
    spec = [l for l in log.splitlines() if l.startswith("ds4 spec:")]
    return (stat[-1] if stat else ""), (dsp[-1] if dsp else ""), (spec[-1] if spec else "")


PCIE = "/sys/devices/pci0000:00/0000:00:1c.4/0000:05:00.0/0000:06:00.0/0000:07:00.0/pcie_bw"


class PcieSampler(threading.Thread):
    """Probkuje pcie_bw hosta (root), bo z kontenera debugfs/sysfs karty nie jest widoczny."""

    def __init__(self):
        super().__init__(daemon=True)
        self.samples = []
        self.go = True

    def run(self):
        while self.go:
            out = sh(f"sudo -n cat {PCIE}").stdout.split()
            if len(out) >= 2:
                try:
                    self.samples.append((int(out[0]), int(out[1])))
                except ValueError:
                    pass
            time.sleep(0.5)

    def stop(self):
        self.go = False
        self.join(timeout=3)

    def _stat(self, idx):
        vals = [s[idx] for s in self.samples]
        if not vals:
            return "", ""
        return round(sum(vals) / len(vals), 1), max(vals)

    def avg_rx(self):
        return self._stat(0)[0]

    def max_rx(self):
        return self._stat(0)[1]

    def avg_tx(self):
        return self._stat(1)[0]

    def max_tx(self):
        return self._stat(1)[1]


def main():
    ram, mode, tag = sys.argv[1], sys.argv[2], sys.argv[3]
    experts = sys.argv[4] if len(sys.argv) > 4 else "64"
    on = mode == "on"
    set_arm(ram, on, experts)
    start()
    t = wait_ready()
    print(f"gotowy po {t:.0f} s")
    log0 = sh(f"docker exec {NAME} cat /data/maya/logs/abyss-server.log").stdout
    for line in log0.splitlines():
        if line.startswith("dspark:") or "drafter=" in line or line.startswith("ds4 dspark:"):
            print("LOAD:", line)
    os.makedirs(os.path.join(HERE, "logs"), exist_ok=True)

    # rozgrzewka (odrzucona)
    ask(PROMPTS[0][1], 60)
    rows = []
    for i in range(5):
        name, p = PROMPTS[i % len(PROMPTS)]
        s = PcieSampler()
        s.start()
        ask(p, 120)
        s.stop()
        stat, dsp, spec = last_stat()
        m = re.search(r"decode ([\d.]+) ms/tok \(([\d.]+) tok/s\) \| vram hit ([\d.]+)% \| "
                      r"ram fetches ([\d.]+)/tok \| disk ([\d.]+) reads/tok.*?\| "
                      r"vram (\d+)/(\d+) ram (\d+)/(\d+)", stat)
        acc = re.search(r"(\d+) drafted, (\d+) accepted = (\d+)%", dsp or spec)
        row = {
            "tag": tag, "ram_gb": ram, "dspark": "on" if on else "off", "prompt": name,
            "tok_s": m.group(2) if m else "", "ms_tok": m.group(1) if m else "",
            "vram_hit": m.group(3) if m else "", "ram_fetch": m.group(4) if m else "",
            "disk_reads": m.group(5) if m else "",
            "slots_vram": (m.group(7) if m else ""), "slots_ram": (m.group(9) if m else ""),
            "accepted_pct": acc.group(3) if acc else "",
            "pcie_rx_avg": s.avg_rx(), "pcie_rx_max": s.max_rx(),
            "pcie_tx_avg": s.avg_tx(), "pcie_tx_max": s.max_tx(),
            "stat": stat, "dspark_line": dsp,
        }
        rows.append(row)
        print(json.dumps({k: v for k, v in row.items() if k not in ("stat", "dspark_line")}))

    with open(os.path.join(HERE, "logs", f"arm-{tag}.log"), "w") as f:
        f.write(sh(f"docker exec {NAME} cat /data/maya/logs/abyss-server.log").stdout)
    csv = os.path.join(HERE, "results.csv")
    cols = ("tag", "ram_gb", "dspark", "prompt", "tok_s", "ms_tok", "vram_hit", "ram_fetch",
            "disk_reads", "slots_vram", "slots_ram", "accepted_pct",
            "pcie_rx_avg", "pcie_rx_max", "pcie_tx_avg", "pcie_tx_max")
    new = not os.path.exists(csv)
    with open(csv, "a") as f:
        if new:
            f.write(",".join(cols) + "\n")
        for r in rows:
            f.write(",".join(str(r[k]) for k in cols) + "\n")
    sh(f"docker rm -f {NAME}")
    print("koniec ramienia", tag)


if __name__ == "__main__":
    main()
